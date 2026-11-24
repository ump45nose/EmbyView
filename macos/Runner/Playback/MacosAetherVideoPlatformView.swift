import AppKit
import FlutterMacOS

/// AppKitView factory for the AetherEngine video surface on macOS. The
/// platform view is screen lifetime while the wrapper and engine are app
/// lifetime, so the view only hosts the wrapper's render view and subtitle
/// overlay while it exists. Same viewType and per-view channel convention as
/// the iOS factory, so the Dart widget works unchanged.
@MainActor
final class MacosAetherVideoViewFactory: NSObject, FlutterPlatformViewFactory {
    static let viewType = "moonfin/aether_video"

    private let messenger: FlutterBinaryMessenger
    private let wrapperProvider: () -> AetherPlayerWrapper

    init(
        messenger: FlutterBinaryMessenger,
        wrapperProvider: @escaping () -> AetherPlayerWrapper
    ) {
        self.messenger = messenger
        self.wrapperProvider = wrapperProvider
        super.init()
    }

    nonisolated func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
        FlutterStandardMessageCodec.sharedInstance()
    }

    // The protocol isn't MainActor annotated, but the engine only calls this
    // on the platform thread.
    nonisolated func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
        MainActor.assumeIsolated {
            MacosAetherVideoContainerView(
                viewId: viewId,
                arguments: args as? [String: Any] ?? [:],
                messenger: messenger,
                wrapper: wrapperProvider())
        }
    }
}

/// Container NSView hosting the engine render view and subtitle overlay.
/// Never participates in hit testing, so every click reaches the Flutter OSD.
final class MacosAetherVideoContainerView: NSView {
    private let channel: FlutterMethodChannel
    private weak var wrapper: AetherPlayerWrapper?

    init(
        viewId: Int64, arguments: [String: Any],
        messenger: FlutterBinaryMessenger, wrapper: AetherPlayerWrapper
    ) {
        channel = FlutterMethodChannel(
            name: "moonfin/aether_video_\(viewId)", binaryMessenger: messenger)
        self.wrapper = wrapper
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        wrapper.attachVideoView(self)
        if let zoom = arguments["zoomMode"] as? String,
            let mode = Self.zoomMode(fromWire: zoom)
        {
            wrapper.setZoomMode(mode)
        }

        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call)
            result(nil)
        }
        channel.invokeMethod("onSurfaceReady", arguments: nil)
        wrapper.notifySurfaceReady()
    }

    required init?(coder: NSCoder) {
        fatalError("This view is only created in code")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { wrapper?.notifySurfaceReady() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func handle(_ call: FlutterMethodCall) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "setZoomMode":
            if let zoom = args["mode"] as? String,
                let mode = Self.zoomMode(fromWire: zoom)
            {
                wrapper?.setZoomMode(mode)
            }
        default:
            break
        }
    }

    /// Accepts the Dart enum names (fit/autoCrop/stretch) and the native raw
    /// values (Fit/Zoom to Fill/Stretch).
    private static func zoomMode(fromWire value: String) -> ZoomMode? {
        switch value {
        case "fit", "Fit": return .fit
        case "autoCrop", "Zoom to Fill": return .zoomToFill
        case "stretch", "Stretch": return .stretch
        default: return nil
        }
    }

    deinit {
        channel.setMethodCallHandler(nil)
        MainActor.assumeIsolated {
            wrapper?.detachVideoView(from: self)
        }
    }
}

/// Public AppKit picture-in-picture for both AVPlayer and sample-buffer output.
/// Reparents the engine's existing render surface, so enhancement, subtitles and
/// the audio clock follow the same session without opening a second player.
@MainActor
final class MacosAetherPictureInPictureController: NSObject, NSWindowDelegate {
    private weak var wrapper: AetherPlayerWrapper?
    private weak var originalHost: NSView?
    private var panel: NSPanel?
    private var restoring = false
    var isActive: Bool { panel != nil }
    init(wrapper: AetherPlayerWrapper) { self.wrapper = wrapper }

    func setEnabled(_ enabled: Bool) throws {
        guard enabled != isActive else { return }
        guard enabled else { restore(); return }
        guard let wrapper, let host = wrapper.videoView, host.window != nil else {
            throw NSError(domain: "EmbyView", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "画面尚未就绪"])
        }
        originalHost = host
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.title = "画中画"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 260, height: 180)
        window.delegate = self
        let root = NSView(frame: window.contentView!.bounds)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        let video = NSView(frame: NSRect(x: 0, y: 36, width: root.bounds.width, height: root.bounds.height - 36))
        video.autoresizingMask = [.width, .height]
        root.addSubview(video)
        let toggle = NSButton(title: "播放 / 暂停", target: self, action: #selector(togglePlayback))
        toggle.frame = NSRect(x: 8, y: 4, width: 120, height: 28)
        let back = NSButton(title: "返回播放器", target: self, action: #selector(returnToPlayer))
        back.frame = NSRect(x: 140, y: 4, width: 120, height: 28)
        root.addSubview(toggle)
        root.addSubview(back)
        window.contentView = root
        panel = window
        wrapper.attachVideoView(video)
        AetherPlayerWrapper.sharedEngine()?.pictureInPictureActive = true
        if let screen = host.window?.screen {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 500, y: screen.visibleFrame.minY + 24))
        }
        window.orderFrontRegardless()
    }
    @objc private func togglePlayback() {
        guard let wrapper else { return }
        wrapper.onNowPlayingCommand?(["event": wrapper.isPlaying ? "pause" : "play"])
    }
    @objc private func returnToPlayer() { restore() }
    func windowWillClose(_ notification: Notification) { restore() }
    private func restore() {
        guard !restoring, let window = panel else { return }
        restoring = true
        panel = nil
        if let originalHost { wrapper?.attachVideoView(originalHost) }
        else if let host = wrapper?.videoView { wrapper?.detachVideoView(from: host) }
        AetherPlayerWrapper.sharedEngine()?.pictureInPictureActive = false
        window.delegate = nil
        window.close()
        originalHost = nil
        restoring = false
        if let wrapper { wrapper.onNativePlaybackEvent?(wrapper.nativePlaybackPayload()) }
    }
}
