import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var menuChannel: FlutterMethodChannel?
  private var appearanceObservation: NSKeyValueObservation?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    updateDockIconForAppearance()
    appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async {
        self?.updateDockIconForAppearance()
      }
    }
  }

  override func applicationWillTerminate(_ notification: Notification) {
    appearanceObservation?.invalidate()
    appearanceObservation = nil
    super.applicationWillTerminate(notification)
  }

  private func updateDockIconForAppearance() {
    let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
    if match == .darkAqua, let darkIcon = NSImage(named: NSImage.Name("AppIconDarkDock")) {
      NSApp.applicationIconImage = darkIcon
    } else {
      NSApp.applicationIconImage = nil
    }
  }

  func bindMenuChannel(_ channel: FlutterMethodChannel) {
    menuChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "updateZones":
        let names = (call.arguments as? [String: Any])?["names"] as? [String] ?? []
        self?.updateZoneMenuItems(names)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func updateZoneMenuItems(_ names: [String]) {
    guard let mainMenu = NSApp.mainMenu else { return }
    for item in mainMenu.items {
      guard let submenu = item.submenu else { continue }
      for idx in 0..<5 {
        guard let zoneItem = submenu.item(withTag: 101 + idx) else { continue }
        if names.isEmpty {
          zoneItem.title = "分区 \(idx + 1)"
          zoneItem.isHidden = false
        } else if idx < names.count {
          zoneItem.title = names[idx]
          zoneItem.isHidden = false
        } else {
          zoneItem.isHidden = true
        }
      }
    }
  }

  private func dispatchMenuAction(_ action: String, completion: ((Any?) -> Void)? = nil) {
    guard let channel = menuChannel else {
      completion?(nil)
      return
    }
    channel.invokeMethod("menuAction", arguments: ["action": action], result: completion)
  }

  // MARK: - EmbyView Menu

  @IBAction func embyViewAbout(_ sender: Any?) {
    dispatchMenuAction("about")
  }

  @IBAction func embyViewSettings(_ sender: Any?) {
    dispatchMenuAction("settings")
  }

  @IBAction func embyViewSignOut(_ sender: Any?) {
    dispatchMenuAction("signOut")
  }

  // MARK: - Edit / Go Menu

  @IBAction func embyViewSearch(_ sender: Any?) {
    dispatchMenuAction("search")
  }

  @IBAction func embyViewGoHome(_ sender: Any?) {
    dispatchMenuAction("goHome")
  }

  @IBAction func embyViewGoZone1(_ sender: Any?) {
    dispatchMenuAction("goZone1")
  }

  @IBAction func embyViewGoZone2(_ sender: Any?) {
    dispatchMenuAction("goZone2")
  }

  @IBAction func embyViewGoZone3(_ sender: Any?) {
    dispatchMenuAction("goZone3")
  }

  @IBAction func embyViewGoZone4(_ sender: Any?) {
    dispatchMenuAction("goZone4")
  }

  @IBAction func embyViewGoZone5(_ sender: Any?) {
    dispatchMenuAction("goZone5")
  }

  @IBAction func embyViewCommandPalette(_ sender: Any?) {
    dispatchMenuAction("commandPalette")
  }

  @IBAction func embyViewBack(_ sender: Any?) {
    dispatchMenuAction("back")
  }

  // MARK: - Playback Menu

  @IBAction func embyViewPlayPause(_ sender: Any?) {
    dispatchMenuAction("playPause")
  }

  @IBAction func embyViewSeekBack10(_ sender: Any?) {
    dispatchMenuAction("seekBack10")
  }

  @IBAction func embyViewSeekForward10(_ sender: Any?) {
    dispatchMenuAction("seekForward10")
  }

  @IBAction func embyViewNextEpisode(_ sender: Any?) {
    dispatchMenuAction("nextEpisode")
  }

  @IBAction func embyViewSubtitlePanel(_ sender: Any?) {
    dispatchMenuAction("subtitlePanel")
  }

  @IBAction func embyViewAiSubtitle(_ sender: Any?) {
    dispatchMenuAction("aiSubtitle")
  }

  @IBAction func embyViewToggleAnime4k(_ sender: Any?) {
    dispatchMenuAction("toggleAnime4k")
  }

  @IBAction func embyViewToggleFullscreen(_ sender: Any?) {
    dispatchMenuAction("toggleFullscreen") { [weak self] result in
      if (result as? Bool) != true {
        self?.mainFlutterWindow?.toggleFullScreen(sender)
      }
    }
  }

  // MARK: - Help Menu

  @IBAction func embyViewShortcuts(_ sender: Any?) {
    dispatchMenuAction("shortcuts")
  }

  @IBAction func embyViewExportDiagnostics(_ sender: Any?) {
    dispatchMenuAction("exportDiagnostics")
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
