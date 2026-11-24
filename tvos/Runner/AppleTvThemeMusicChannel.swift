import AVFoundation
#if canImport(Flutter)
    import Flutter
#elseif canImport(FlutterMacOS)
    import FlutterMacOS
#endif

@MainActor
final class AppleTvThemeMusicChannel: NSObject, FlutterStreamHandler {
    private let channel: FlutterMethodChannel
    private let events: FlutterEventChannel
    private var eventSink: FlutterEventSink?
    private var queuePlayer: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var timeObserver: Any?
    private var itemObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var currentToken: Int = -1
    private var state = "idle"

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "moonfin/appletv_theme_music", binaryMessenger: messenger)
        events = FlutterEventChannel(name: "moonfin/appletv_theme_music_events", binaryMessenger: messenger)
        super.init()
        events.setStreamHandler(self)
        channel.setMethodCallHandler { [weak self] call, result in
            Task { @MainActor in self?.handle(call, result: result) }
        }
    }
    nonisolated func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
        MainActor.assumeIsolated { self.eventSink = eventSink; emitState() }
        return nil
    }
    nonisolated func onCancel(withArguments arguments: Any?) -> FlutterError? {
        MainActor.assumeIsolated { eventSink = nil }
        return nil
    }
    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        let token = (args["token"] as? NSNumber)?.intValue ?? -1
        switch call.method {
        case "open":
            guard let string = args["url"] as? String, let url = URL(string: string) else { result(nil); return }
            open(url: url, token: token, headers: args["headers"] as? [String: String] ?? [:])
        case "setVolume":
            if token == currentToken {
                queuePlayer?.volume = max(0, min(1, ((args["volume"] as? NSNumber)?.floatValue ?? 0) / 100))
                emitState()
            }
        case "setMuted":
            if token == currentToken { queuePlayer?.isMuted = args["muted"] as? Bool ?? true; emitState() }
        case "stop": if token == currentToken { stop() }
        default: result(FlutterMethodNotImplemented); return
        }
        result(nil)
    }
    private func open(url: URL, token: Int, headers: [String: String]) {
        stop()
        currentToken = token
        state = "loading"
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        let queue = AVQueuePlayer(playerItem: item)
        queue.volume = 0
        queuePlayer = queue
        looper = AVPlayerLooper(player: queue, templateItem: item)
        itemObservation = queue.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.itemStatusObservation = self.queuePlayer?.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor in self?.emitState() }
                }
                self.emitState()
            }
        }
        timeObserver = queue.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.emitState() }
        }
        queue.play()
        emitState()
    }
    private func emitState() {
        let item = queuePlayer?.currentItem
        if item?.status == .failed { state = "failed" }
        else if item?.status == .readyToPlay { state = "ready" }
        var payload: [String: Any] = ["token": currentToken, "state": state,
            "positionMs": milliseconds(queuePlayer?.currentTime().seconds),
            "muted": queuePlayer?.isMuted == true || queuePlayer?.volume == 0]
        let duration = item?.duration.seconds
        if let duration, duration.isFinite, duration > 0 { payload["durationMs"] = milliseconds(duration) }
        if let error = item?.error { payload["reason"] = error.localizedDescription }
        eventSink?(payload)
    }
    private func milliseconds(_ value: Double?) -> Int64 {
        guard let value, value.isFinite else { return 0 }
        return Int64((max(0, value) * 1000).rounded())
    }
    private func stop() {
        itemObservation = nil
        itemStatusObservation = nil
        if let timeObserver { queuePlayer?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        looper?.disableLooping()
        looper = nil
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        queuePlayer = nil
        state = "idle"
        emitState()
        currentToken = -1
    }
}
