import AetherEngine
import AVFoundation
import Combine
import FlutterMacOS

/// The engine's lossy PCM tap plus a bounded, acknowledgement-driven Flutter bridge.
/// At most 16 packets (512 KiB) wait here and one batch (128 KiB) is in flight.
/// Seek, source, audio selection and pipeline rebuilds retire the old timeline.
@MainActor
final class EmbyViewAudioChannel: NSObject, FlutterStreamHandler {
    private let control: FlutterMethodChannel
    private let events: FlutterEventChannel
    private let wrapperProvider: () -> AetherPlayerWrapper
    private var sink: FlutterEventSink?
    private var reader: Task<Void, Never>?
    private var timer: Timer?
    private var readyObserver: AnyCancellable?
    private var audioTrackObserver: AnyCancellable?
    private var seekingObserver: AnyCancellable?
    private var lastAudioTrackID: Int?
    private var queue: [[String: Any]] = []
    private var requested = false
    private var dialogue = true
    private var timelineGeneration = 0
    private var inFlight: Int?
    private var sequence = 0
    private var needsDiscontinuity = true
    private var activeSourceGeneration = 0
    private var boundaryPending = false
    private var waitingForRebuild = false

    init(messenger: FlutterBinaryMessenger, wrapperProvider: @escaping () -> AetherPlayerWrapper) {
        self.wrapperProvider = wrapperProvider
        control = FlutterMethodChannel(name: "embyview/audio_control", binaryMessenger: messenger)
        events = FlutterEventChannel(name: "embyview/audio_events", binaryMessenger: messenger)
        super.init()
        events.setStreamHandler(self)
        let wrapper = wrapperProvider()
        wrapper.onAudioInputBoundary = { [weak self] reason, ready in self?.boundary(reason, ready: ready) }
        readyObserver = AetherPlayerWrapper.sharedEngine()?.$isSessionReady
            .receive(on: DispatchQueue.main).sink { [weak self] ready in
                guard let self, self.requested else { return }
                if ready && !self.boundaryPending { self.installIfReady() }
                else if !ready {
                    if self.waitingForRebuild { self.boundaryPending = false; self.waitingForRebuild = false }
                    self.retire(reason: "pipeline")
                }
            }
        if let engine = AetherPlayerWrapper.sharedEngine() {
            seekingObserver = engine.$isSeeking.receive(on: DispatchQueue.main).sink { [weak self] seeking in
                guard let self, self.requested else { return }
                if seeking { self.retire(reason: "seek") }
                else if !self.boundaryPending { self.installIfReady() }
            }
            lastAudioTrackID = engine.activeAudioTrackIndex
            audioTrackObserver = engine.$activeAudioTrackIndex.receive(on: DispatchQueue.main).sink { [weak self] id in
                guard let self, id != self.lastAudioTrackID else { return }
                self.lastAudioTrackID = id
                guard self.requested, self.waitingForRebuild else { return }
                self.waitingForRebuild = false
                self.boundaryPending = false
                self.retire(reason: "audioTrackChanged")
                self.installIfReady()
            }
        }
        control.setMethodCallHandler { [weak self] call, result in
            Task { @MainActor in
                guard let self else { result(nil); return }
                let args = call.arguments as? [String: Any] ?? [:]
                switch call.method {
                case "start":
                    self.requested = true
                    self.dialogue = args["dialogue"] as? Bool ?? true
                    self.retire(reason: "start")
                    result(self.installIfReady())
                case "stop":
                    self.requested = false
                    self.retire(reason: "stop")
                    result(nil)
                case "ack":
                    if (args["sequence"] as? NSNumber)?.intValue == self.inFlight { self.inFlight = nil }
                    self.drain()
                    result(nil)
                case "aheadAvailability":
                    result(["available": false, "reason": "前方音频探针尚未接入；当前端口只提供播放时间线 PCM"])
                default: result(FlutterMethodNotImplemented)
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drain() }
        }
    }
    nonisolated func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
        MainActor.assumeIsolated { sink = eventSink; inFlight = nil }
        return nil
    }
    nonisolated func onCancel(withArguments arguments: Any?) -> FlutterError? {
        MainActor.assumeIsolated {
            sink = nil
            requested = false
            inFlight = nil
            retire(reason: "cancel")
        }
        return nil
    }
    private func boundary(_ reason: String, ready: Bool) {
        if !ready {
            boundaryPending = ["source", "seek", "enhancement", "audioTrack"].contains(reason)
            waitingForRebuild = reason == "audioTrack"
            retire(reason: reason)
            if reason == "stop" { requested = false }
        } else {
            boundaryPending = false
            if requested { installIfReady() }
        }
    }
    private func retire(reason: String) {
        timelineGeneration &+= 1
        reader?.cancel()
        reader = nil
        AetherPlayerWrapper.sharedEngine()?.removeAudioTap()
        queue.removeAll(keepingCapacity: true)
        // Keep an unacknowledged batch in flight: clearing it would allow unbounded
        // old batches to accumulate in Flutter's platform queue across repeated seeks.
        needsDiscontinuity = true
        sink?(["event": "audioState", "state": "boundary", "reason": reason,
               "sourceGeneration": wrapperProvider().sourceGeneration, "timelineGeneration": timelineGeneration])
    }
    @discardableResult private func installIfReady() -> Bool {
        guard requested, !boundaryPending, reader == nil, let engine = AetherPlayerWrapper.sharedEngine(),
              engine.isSessionReady, !engine.isSeeking else { return reader != nil }
        activeSourceGeneration = wrapperProvider().sourceGeneration
        let stream = engine.installAudioTap(channels: dialogue ? .dialogue : .downmix)
        guard engine.audioTapHasDeliverySource else {
            sink?(["event": "audioState", "state": "unavailable", "sourceGeneration": activeSourceGeneration,
                   "timelineGeneration": timelineGeneration])
            return false
        }
        let generation = timelineGeneration
        sink?(["event": "audioState", "state": "ready", "sourceGeneration": activeSourceGeneration,
               "timelineGeneration": generation])
        reader = Task { [weak self] in
            for await packet in stream {
                guard !Task.isCancelled, let self, self.timelineGeneration == generation else { return }
                self.enqueue(packet)
            }
            guard let self, !Task.isCancelled, self.timelineGeneration == generation else { return }
            self.reader = nil
            self.retire(reason: "pipelineEnded")
            // Engine reloads finish taps. Readiness's rising edge reinstalls it.

        }
        return true
    }
    private func enqueue(_ packet: AudioTapBuffer) {
        guard let engine = AetherPlayerWrapper.sharedEngine(),
              wrapperProvider().sourceGeneration == activeSourceGeneration,
              let samples = packet.buffer.floatChannelData?[0] else { return }
        let total = Int(packet.buffer.frameLength)
        let offset = engine.sourceTime - engine.clock.currentTime
        for start in stride(from: 0, to: total, by: 8192) {
            let frames = min(8192, total - start)
            let sourceTime = packet.sourceTime + Double(start) / 48000
            let data = Data(bytes: samples.advanced(by: start), count: frames * MemoryLayout<Float>.size)
            if queue.count >= 16 { queue.removeFirst(); needsDiscontinuity = true }
            queue.append([
                "pcm": FlutterStandardTypedData(bytes: data), "sampleRate": 48000, "channels": 1,
                "format": "float32le", "sourceGeneration": activeSourceGeneration,
                "timelineGeneration": timelineGeneration,
                "sourceTimeUs": Int64((sourceTime * 1_000_000).rounded()),
                "playbackTimeUs": Int64(((sourceTime - offset) * 1_000_000).rounded()),
                "discontinuity": packet.discontinuity && start == 0,
                "dialogue": packet.channels == .dialogue,
            ])
        }
    }
    private func drain() {
        guard let sink, inFlight == nil, !queue.isEmpty else { return }
        let count = min(4, queue.count)
        var batch = Array(queue.prefix(count))
        queue.removeFirst(count)
        if needsDiscontinuity { batch[0]["discontinuity"] = true; needsDiscontinuity = false }
        sequence &+= 1
        inFlight = sequence
        sink(["event": "pcm", "sequence": sequence, "buffers": batch])
    }
}
