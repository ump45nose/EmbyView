import AetherEngine
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import AetherLibswresample
import AVFoundation
import Combine
import FlutterMacOS
import Foundation

/// The engine's lossy PCM tap plus a bounded, acknowledgement-driven Flutter bridge.
/// At most 16 packets (512 KiB) wait here and one batch (128 KiB) is in flight.
/// Seek, source, audio selection and pipeline rebuilds retire the old timeline.
@MainActor
final class EmbyViewAudioChannel: NSObject, FlutterStreamHandler {
    private let control: FlutterMethodChannel
    private let events: FlutterEventChannel
    private let boundaries: SubtitleAudioBoundaryChannel
    private let wrapperProvider: () -> AetherPlayerWrapper
    private var sink: FlutterEventSink?
    private var reader: Task<Void, Never>?
    private var timer: Timer?
    private var readyObserver: AnyCancellable?
    private var audioTrackObserver: AnyCancellable?
    private var seekingObserver: AnyCancellable?
    private var seekEventsObserver: AnyCancellable?
    private var subtitleSeek: (id: UInt64, generation: Int)?
    private var lastAudioTrackID: Int?
    private var queue: [[String: Any]] = []
    private var requested = false
    private var dialogue = true
    private var timelineGeneration = 0
    private var inFlight: Int?
    private var sequence = 0
    private var needsDiscontinuity = true
    private var activeSourceGeneration = 0
    private var lastTapPosition: Double?
    private var boundaryPending = false
    private var waitingForRebuild = false
    private var independentRead: (id: Int, control: SubtitleReadControl)?

    init(messenger: FlutterBinaryMessenger, wrapperProvider: @escaping () -> AetherPlayerWrapper) {
        self.wrapperProvider = wrapperProvider
        control = FlutterMethodChannel(name: "embyview/audio_control", binaryMessenger: messenger)
        events = FlutterEventChannel(name: "embyview/audio_events", binaryMessenger: messenger)
        boundaries = SubtitleAudioBoundaryChannel(messenger: messenger)
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
            // Unlike the isSeeking level, a landing identifies the actual seek
            // and won't resume subtitles after a superseded or stalled request.
            seekEventsObserver = engine.seekEvents.sink { [weak self] event in
                guard let self else { return }
                let generation = self.wrapperProvider().sourceGeneration
                switch event.outcome {
                case .began:
                    self.subtitleSeek = (event.id, generation)
                    self.publishBoundary("seek", ready: false)
                case .landed(let position):
                    guard self.subtitleSeek?.id == event.id, self.subtitleSeek?.generation == generation else { return }
                    self.subtitleSeek = nil
                    self.publishBoundary("seek", ready: true, position: position)
                default: break
                }
            }
            seekingObserver = engine.$isSeeking.receive(on: DispatchQueue.main).sink { [weak self] seeking in
                guard let self, self.requested else { return }
                if seeking { self.retire(reason: "seek") }
                else if !self.boundaryPending { self.installIfReady() }
            }
            lastAudioTrackID = engine.activeAudioTrackIndex
            audioTrackObserver = engine.$activeAudioTrackIndex.receive(on: DispatchQueue.main).sink { [weak self] id in
                guard let self, id != self.lastAudioTrackID else { return }
                self.lastAudioTrackID = id
                if id == AetherPlayerWrapper.sharedEngine()?.activeAudioTrackIndex {
                    self.publishBoundary("audioTrack", ready: true, streamIndex: id)
                }
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
                case "readIndependent": self.readIndependent(args, result: result)
                case "cancelIndependent":
                    if self.independentRead?.id == args["requestId"] as? Int {
                        self.independentRead?.control.cancel()
                    }
                    result(nil)
                default: result(FlutterMethodNotImplemented)
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkTapDelivery()
                self?.drain()
            }
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
        if reason == "audioTrack" { publishBoundary(reason, ready: ready) }
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

    private func publishBoundary(_ kind: String, ready: Bool, position: Double? = nil, streamIndex: Int? = nil) {
        guard let sink = boundaries.sink else { return }
        var event: [String: Any] = ["kind": kind, "ready": ready, "sourceGeneration": wrapperProvider().sourceGeneration]
        if let seconds = position ?? AetherPlayerWrapper.sharedEngine()?.clock.currentTime, seconds.isFinite, seconds >= 0 {
            event["positionUs"] = Int64((min(seconds, 9_000_000_000) * 1_000_000).rounded())
        }
        if let streamIndex, streamIndex >= 0 { event["streamIndex"] = streamIndex }
        sink(event)
    }
    private func retire(reason: String) {
        timelineGeneration &+= 1
        reader?.cancel()
        reader = nil
        lastTapPosition = nil
        AetherPlayerWrapper.sharedEngine()?.removeAudioTap()
        queue.removeAll(keepingCapacity: true)
        // Keep an unacknowledged batch in flight: clearing it would allow unbounded
        // old batches to accumulate in Flutter's platform queue across repeated seeks.
        needsDiscontinuity = true
        sink?(["event": "audioState", "state": "boundary", "reason": reason,
               "sourceGeneration": wrapperProvider().sourceGeneration, "timelineGeneration": timelineGeneration])
    }

    private func endTap(error code: String? = nil) {
        requested = false
        retire(reason: code ?? "ended")
        if let code { sink?(FlutterError(code: code, message: nil, details: nil)) }
        else { sink?(FlutterEndOfEventStream) }
    }

    private func checkTapDelivery() {
        guard requested, !boundaryPending, let engine = AetherPlayerWrapper.sharedEngine() else { return }
        let position = engine.clock.currentTime
        guard position.isFinite else { return }
        guard engine.state == .playing, engine.isSessionReady, !engine.isSeeking, !engine.isBuffering else {
            lastTapPosition = position
            return
        }
        let last = lastTapPosition ?? position
        // Measure a missing window on the advancing playhead, so pause and
        // buffering never consume the tap's allowance.
        if position - last >= 30 { endTap(error: "audioTapInterrupted") }
        else { lastTapPosition = min(position, last) }
    }

    @discardableResult private func installIfReady() -> Bool {
        guard requested, !boundaryPending, reader == nil, let engine = AetherPlayerWrapper.sharedEngine(),
              engine.isSessionReady, !engine.isSeeking else { return reader != nil }
        activeSourceGeneration = wrapperProvider().sourceGeneration
        let stream = engine.installAudioTap(channels: dialogue ? .dialogue : .downmix)
        guard engine.audioTapHasDeliverySource else {
            sink?(["event": "audioState", "state": "unavailable", "sourceGeneration": activeSourceGeneration,
                   "timelineGeneration": timelineGeneration])
            endTap(error: "audioTapUnavailable")
            return false
        }
        lastTapPosition = engine.clock.currentTime
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
            if engine.state == .ended {
                self.endTap()
            } else if (engine.state == .playing || engine.state == .paused) && engine.isSessionReady &&
                        !engine.isSeeking && !engine.isBuffering && !self.boundaryPending {
                self.endTap(error: "audioTapInterrupted")
            } else {
                // A rebuilding engine ends its old tap. Readiness reinstalls it.
                self.retire(reason: "pipelineEnded")
            }
        }
        return true
    }
    private func enqueue(_ packet: AudioTapBuffer) {
        guard let engine = AetherPlayerWrapper.sharedEngine(),
              wrapperProvider().sourceGeneration == activeSourceGeneration,
              let samples = packet.buffer.floatChannelData?[0] else { return }
        let total = Int(packet.buffer.frameLength)
        if total > 0 { lastTapPosition = engine.clock.currentTime }
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

    private func readIndependent(_ args: [String: Any], result: @escaping FlutterResult) {
        guard let id = args["requestId"] as? Int, let input = SubtitleReadInput(args) else {
            result(FlutterError(code: "audioInput", message: "无效的音频输入或时间范围", details: nil))
            return
        }
        guard independentRead == nil else {
            result(FlutterError(code: "audioBusy", message: "已有独立音频读取在运行", details: nil))
            return
        }
        let control = SubtitleReadControl()
        independentRead = (id, control)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let decoded = Result { try input.read(control: control) }
            DispatchQueue.main.async { [weak self] in
                self?.independentRead = nil
                switch decoded {
                case .success(let chunks):
                    result(chunks.map {
                        ["startUs": $0.playbackStart, "sourceUs": $0.start,
                         "pcm": FlutterStandardTypedData(bytes: $0.pcm)]
                    })
                case .failure(let failure):
                    let error = failure as? SubtitleReadError ?? SubtitleReadError("audioRead")
                    result(FlutterError(code: error.code, message: "独立音频读取失败", details: error.detail))
                }
            }
        }
    }
}

@MainActor
private final class SubtitleAudioBoundaryChannel: NSObject, FlutterStreamHandler {
    let channel: FlutterEventChannel
    var sink: FlutterEventSink?

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterEventChannel(name: "embyview/audio_boundaries", binaryMessenger: messenger)
        super.init()
        channel.setStreamHandler(self)
    }

    nonisolated func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
        MainActor.assumeIsolated { sink = eventSink }
        return nil
    }

    nonisolated func onCancel(withArguments arguments: Any?) -> FlutterError? {
        MainActor.assumeIsolated { sink = nil }
        return nil
    }
}

private struct SubtitleReadError: Error {
    let code: String
    let detail: Int32

    init(_ code: String, _ detail: Int32 = 0) {
        self.code = code
        self.detail = detail
    }
}

private final class SubtitleReadControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let deadline = DispatchTime.now() + .seconds(35)

    func cancel() { lock.withLock { cancelled = true } }
    var failure: SubtitleReadError? {
        if lock.withLock({ cancelled }) { return SubtitleReadError("audioInterrupted") }
        return DispatchTime.now() >= deadline ? SubtitleReadError("audioTimeout") : nil
    }
    var stopped: Bool { failure != nil }
}

private struct SubtitleReadChunk: Sendable {
    let start: Int64
    let playbackStart: Int64
    var pcm: Data
    var end: Int64 { start + Int64((Double(pcm.count / 4) * 1_000_000 / 48_000).rounded()) }
}

private struct SubtitleReadInput: Sendable {
    let url: URL
    let headers: [String: String]
    let userAgent: String
    let start: Int64
    let end: Int64
    let streamIndex: Int32?

    init?(_ args: [String: Any]) {
        guard let address = args["address"] as? String, let url = URL(string: address),
              let scheme = url.scheme, ["file", "http", "https"].contains(scheme.lowercased()),
              let userAgent = args["userAgent"] as? String,
              let start = (args["startUs"] as? NSNumber)?.int64Value,
              let end = (args["endUs"] as? NSNumber)?.int64Value,
              start >= 0, end > start, end - start <= 30_000_000, end <= 9_000_000_000_000_000 else { return nil }
        self.url = url
        headers = args["headers"] as? [String: String] ?? [:]
        self.userAgent = userAgent
        self.start = start
        self.end = end
        streamIndex = (args["streamIndex"] as? NSNumber)?.int32Value
    }

    func read(control: SubtitleReadControl) throws -> [SubtitleReadChunk] {
        var format = avformat_alloc_context()
        guard let context = format else { throw SubtitleReadError("audioDecoder") }
        context.pointee.interrupt_callback = AVIOInterruptCB(callback: { state in
            guard let state else { return 1 }
            return Unmanaged<SubtitleReadControl>.fromOpaque(state).takeUnretainedValue().stopped ? 1 : 0
        }, opaque: Unmanaged.passUnretained(control).toOpaque())
        let network = url.isFileURL ? nil : SubtitleRangeInput(input: self, control: control)
        var io: UnsafeMutablePointer<AVIOContext>?
        var options: OpaquePointer?
        defer {
            avformat_close_input(&format)
            if let io { av_free(io.pointee.buffer) }
            avio_context_free(&io)
            av_dict_free(&options)
            network?.close()
        }
        if let network {
            io = try network.makeIO()
            context.pointee.pb = io
            context.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
        }
        av_dict_set(&options, "skip_attachments", "1", 0)
        // Subordinate URLs cannot borrow this byte input or its authorization.
        av_dict_set(&options, "protocol_whitelist", url.isFileURL ? "file" : "none", 0)
        func check(_ status: Int32, _ code: String) throws {
            if let failure = control.failure { throw failure }
            if status < 0 { throw network?.failure ?? SubtitleReadError(code, status) }
        }
        try check(avformat_open_input(&format, url.isFileURL ? url.path : url.lastPathComponent, nil, &options), "audioOpen")
        guard let format else { throw SubtitleReadError("audioOpen") }
        try check(avformat_find_stream_info(format, nil), "audioStreams")
        let index = streamIndex ?? av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        guard index >= 0, index < format.pointee.nb_streams, let stream = format.pointee.streams[Int(index)],
              let parameters = stream.pointee.codecpar, parameters.pointee.codec_type == AVMEDIA_TYPE_AUDIO,
              let decoder = avcodec_find_decoder(parameters.pointee.codec_id) else { throw SubtitleReadError("audioTrack") }
        var codec = avcodec_alloc_context3(decoder)
        var packet = av_packet_alloc()
        var frame = av_frame_alloc()
        var output = av_frame_alloc()
        var resampler = swr_alloc()
        defer {
            swr_free(&resampler)
            av_frame_free(&output)
            av_frame_free(&frame)
            av_packet_free(&packet)
            avcodec_free_context(&codec)
        }
        guard let codec, let packet, let frame, let output, let resampler else {
            throw SubtitleReadError("audioDecoder")
        }
        try check(avcodec_parameters_to_context(codec, parameters), "audioDecoder")
        codec.pointee.pkt_timebase = stream.pointee.time_base
        try check(avcodec_open2(codec, decoder, nil), "audioDecoder")
        let base = AVRational(num: 1, den: 1_000_000)
        let rawOrigin = format.pointee.start_time
        let origin = rawOrigin == Int64.min ? 0 : rawOrigin
        guard (-9_000_000_000_000_000...9_000_000_000_000_000).contains(origin) else { throw SubtitleReadError("audioPTS") }
        if start > 0 {
            let time = origin + max(0, start - 250_000)
            try check(avformat_seek_file(format, -1, Int64.min, time, time, 0), "audioSeek")
        }
        var chunks: [SubtitleReadChunk] = []
        var anchor: Int64?
        var samples: Int64 = 0
        var remaining = ((end - start) * 48_000 + 500_000) / 1_000_000
        var done = false

        func render(_ input: UnsafeMutablePointer<AVFrame>?) throws {
            if let input {
                let rawPTS = input.pointee.best_effort_timestamp
                if rawPTS != Int64.min {
                    let pts = av_rescale_q(rawPTS, stream.pointee.time_base, base)
                    guard (-9_000_000_000_000_000...9_000_000_000_000_000).contains(pts) else { throw SubtitleReadError("audioPTS") }
                    if anchor == nil || abs(pts - ((anchor ?? pts) + samples * 1_000_000 / 48_000)) > 2_000 {
                        swr_close(resampler)
                        anchor = pts
                        samples = 0
                    }
                }
                // FFmpeg can report an unspecified layout even for PCM mono. Normalize
                // the frame before swr compares it with its configured layout.
                let channels = input.pointee.ch_layout.nb_channels
                if input.pointee.ch_layout.order == AV_CHANNEL_ORDER_UNSPEC {
                    av_channel_layout_default(&input.pointee.ch_layout, channels)
                }
                let sampleFormat = AVSampleFormat(rawValue: input.pointee.format)
                let planeCount = av_sample_fmt_is_planar(sampleFormat) != 0 ? Int(channels) : 1
                guard channels > 0, input.pointee.sample_rate > 0,
                      Int64(input.pointee.nb_samples) * 48_000 / Int64(input.pointee.sample_rate) <= 192_000,
                      let planes = input.pointee.extended_data,
                      (0..<planeCount).allSatisfy({ planes[$0] != nil }) else { throw SubtitleReadError("audioDecode") }
            }
            guard let anchor else { return }
            let pts = anchor + samples * 1_000_000 / 48_000
            let playback = pts - origin
            if playback >= end { done = true; return }
            av_frame_unref(output)
            output.pointee.format = AV_SAMPLE_FMT_FLT.rawValue
            output.pointee.sample_rate = 48_000
            av_channel_layout_default(&output.pointee.ch_layout, 1)
            var status = swr_convert_frame(resampler, output, input)
            if status == -0x636e6701 && input != nil { // AVERROR_INPUT_CHANGED
                swr_close(resampler)
                status = swr_convert_frame(resampler, output, input)
            }
            try check(status, "audioResample")
            let frames = Int64(output.pointee.nb_samples)
            samples += frames
            let first = max(0, Int64((Double(start - playback) * 48_000 / 1_000_000).rounded()))
            let last = min(frames, first + remaining, Int64((Double(end - playback) * 48_000 / 1_000_000).rounded()))
            done = last < frames
            guard first < last, let bytes = output.pointee.data.0 else { return }
            remaining -= last - first
            done = done || remaining == 0
            let clippedPTS = pts + first * 1_000_000 / 48_000
            let clipped = Data(bytes: bytes.advanced(by: Int(first) * 4), count: Int(last - first) * 4)
            if let previous = chunks.last, abs(previous.end - clippedPTS) <= 22 {
                chunks[chunks.count - 1].pcm.append(clipped)
            } else {
                // Align independently read windows at their shared sample boundary.
                let time = clippedPTS - origin
                let playbackStart = abs(time - start) <= 11 ? start : time
                chunks.append(SubtitleReadChunk(start: clippedPTS, playbackStart: playbackStart, pcm: clipped))
            }
        }
        func receive() throws {
            while !done {
                let status = avcodec_receive_frame(codec, frame)
                if status == -EAGAIN || status == -0x20464F45 { break }
                try check(status, "audioDecode")
                try render(frame)
            }
        }
        while !done {
            try check(0, "audioRead")
            let status = av_read_frame(format, packet)
            if status == -0x20464F45 {
                if let failure = network?.failure { throw failure }
                try check(avcodec_send_packet(codec, nil), "audioDecode")
                try receive()
                if !done && swr_is_initialized(resampler) != 0 { try render(nil) }
                break
            }
            try check(status, "audioRead")
            if packet.pointee.stream_index == index {
                try check(avcodec_send_packet(codec, packet), "audioDecode")
                try receive()
            }
            av_packet_unref(packet)
        }
        try check(0, "audioRead")
        return chunks
    }
}

// The shipped FFmpeg build has no HTTP protocol. Use the authorized playback
// address through a seekable, bounded URLSession input.
private final class SubtitleRangeInput: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private final class Transfer: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var result: Result<(bytes: Data, length: Int64, address: URL?), Error>?
    }

    private static let blockSize = 2_097_152
    private let input: SubtitleReadInput
    private let control: SubtitleReadControl
    private var session: URLSession!
    private var address: URL
    private var position: Int64 = 0
    private var length: Int64?
    private var cachedStart: Int64 = 0
    private var cachedData = Data()
    private(set) var failure: SubtitleReadError?

    init(input: SubtitleReadInput, control: SubtitleReadControl) {
        self.input = input
        self.control = control
        address = input.url
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func close() { session.invalidateAndCancel() }

    func makeIO() throws -> UnsafeMutablePointer<AVIOContext> {
        guard let memory = av_malloc(32768)?.assumingMemoryBound(to: UInt8.self) else { throw SubtitleReadError("audioInput") }
        guard let io = avio_alloc_context(memory, 32768, 0, Unmanaged.passUnretained(self).toOpaque(), { value, bytes, count in
            guard let value, let bytes else { return -EIO }
            return Unmanaged<SubtitleRangeInput>.fromOpaque(value).takeUnretainedValue().read(bytes, count: count)
        }, nil, { value, offset, whence in
            guard let value else { return -Int64(EIO) }
            return Unmanaged<SubtitleRangeInput>.fromOpaque(value).takeUnretainedValue().seek(offset, whence: whence)
        }) else {
            av_free(memory)
            throw SubtitleReadError("audioInput")
        }
        io.pointee.seekable = AVIO_SEEKABLE_NORMAL
        return io
    }

    private func read(_ bytes: UnsafeMutablePointer<UInt8>, count: Int32) -> Int32 {
        if control.stopped { return -EINTR }
        if let length, position >= length { return -0x20464F45 }
        let size = Int64(Self.blockSize)
        let block = position / size * size
        guard block <= Int64.max - size else { return -EIO }
        if cachedData.isEmpty || cachedStart != block {
            do {
                try fetch(start: block, end: block + size - 1)
            } catch {
                failure = error as? SubtitleReadError ?? SubtitleReadError("audioNetwork")
                return -EIO
            }
        }
        let offset = Int(position - cachedStart)
        let actual = min(Int(count), cachedData.count - offset)
        guard actual > 0 else { return -0x20464F45 }
        cachedData.copyBytes(to: bytes, from: offset..<(offset + actual))
        position += Int64(actual)
        return Int32(actual)
    }

    private func seek(_ offset: Int64, whence: Int32) -> Int64 {
        if control.stopped { return -Int64(EINTR) }
        let base: Int64
        switch whence & ~AVSEEK_FORCE {
        case AVSEEK_SIZE: return length ?? -1
        case SEEK_SET: base = 0
        case SEEK_CUR: base = position
        case SEEK_END:
            guard let length else { return -1 }
            base = length
        default: return -1
        }
        let (next, overflow) = base.addingReportingOverflow(offset)
        guard !overflow, next >= 0 else { return -1 }
        position = next
        return position
    }

    private func request(_ url: URL, range: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        let origin = input.url
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        if url.scheme?.lowercased() == origin.scheme?.lowercased(),
           url.host?.lowercased() == origin.host?.lowercased(), port(url) == port(origin) {
            for (header, value) in input.headers { request.setValue(value, forHTTPHeaderField: header) }
        }
        request.setValue(input.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(range, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    private func fetch(start: Int64, end: Int64) throws {
        let pending = Transfer()
        let request = request(address, range: "bytes=\(start)-\(end)")
        let task = Task.detached { [session] in
            defer { pending.done.signal() }
            do {
                let (stream, response) = try await session!.bytes(for: request)
                defer { stream.task.cancel() }
                guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
                    throw SubtitleReadError("audioHttp", Int32((response as? HTTPURLResponse)?.statusCode ?? 0))
                }
                guard let range = http.value(forHTTPHeaderField: "Content-Range"), range.hasPrefix("bytes \(start)-"),
                      let total = Int64(range.split(separator: "/").last ?? ""), total > start else {
                    throw SubtitleReadError("audioRange")
                }
                let expected = min(Self.blockSize, Int(total - start))
                guard response.expectedContentLength <= expected else { throw SubtitleReadError("audioRange") }
                var data = Data(capacity: expected)
                for try await byte in stream {
                    guard data.count < expected else { throw SubtitleReadError("audioRange") }
                    data.append(byte)
                }
                guard data.count == expected else { throw SubtitleReadError("audioRange") }
                pending.result = .success((data, total, response.url))
            } catch let error as URLError where error.code == .timedOut {
                pending.result = .failure(SubtitleReadError("audioTimeout"))
            } catch { pending.result = .failure(error) }
        }
        while pending.done.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if let failure = control.failure { task.cancel(); throw failure }
        }
        let range = try pending.result!.get()
        length = range.length
        address = range.address ?? address
        cachedStart = start
        cachedData = range.bytes
        failure = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = newRequest.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let range = task.originalRequest?.value(forHTTPHeaderField: "Range") else { completionHandler(nil); return }
        completionHandler(request(url, range: range))
    }

}
