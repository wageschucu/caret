import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem!
  private let controller = Controller()
  private var statusLine: NSMenuItem!
  private var pauseItem: NSMenuItem!
  private var contextItem: NSMenuItem!
  private let statusWindow = StatusWindow()

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let image = NSImage(systemSymbolName: "arrow.up.right.circle.fill", accessibilityDescription: "Caret") {
      image.isTemplate = true
      statusItem.button?.image = image
    } else {
      statusItem.button?.title = "↗"
    }
    let menu = NSMenu()
    statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    statusLine.isEnabled = false
    menu.addItem(statusLine)
    menu.addItem(.separator())
    pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")
    pauseItem.target = self
    menu.addItem(pauseItem)
    contextItem = NSMenuItem(title: "Include recent windows as context", action: #selector(toggleContext), keyEquivalent: "")
    contextItem.target = self
    menu.addItem(contextItem)
    menu.addItem(withTitle: "Copy last state (debug)", action: #selector(copyState), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Open helper page", action: #selector(openHelper), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Open Accessibility settings", action: #selector(openAccessibility), keyEquivalent: "")
      .target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Caret", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    menu.delegate = self
    statusItem.menu = menu

    statusWindow.onOpenSettings = { [weak self] in self?.openAccessibility() }
    statusWindow.onQuit = { NSApp.terminate(nil) }
    controller.onStatus = { [weak self] text in
      self?.statusLine.title = text
      // Anything other than a connected, trusted state deserves a visible window.
      let ok = text.hasPrefix("Helper:") && !text.contains("waiting")
      self?.statusWindow.update(status: text, needsAttention: !ok)
    }
    controller.start()
  }

  @objc private func togglePause() {
    Settings.paused.toggle()
    controller.pausedChanged()
  }
  @objc private func toggleContext() { Settings.screenContext.toggle() }
  @objc private func copyState() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(controller.lastStateJSON, forType: .string)
  }
  @objc private func openHelper() { NSWorkspace.shared.open(Settings.helperURL) }
  @objc private func openAccessibility() {
    NSWorkspace.shared.open(
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
  }
}

extension AppDelegate: NSMenuDelegate {
  func menuWillOpen(_ menu: NSMenu) {
    pauseItem.state = Settings.paused ? .on : .off
    contextItem.state = Settings.screenContext ? .on : .off
  }
}
