import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem!
  private let controller = Controller()
  private var statusLine: NSMenuItem!
  private var pauseItem: NSMenuItem!
  private var contextItem: NSMenuItem!
  private var loginItem: NSMenuItem!
  private let statusWindow = StatusWindow()

  private var menu: NSMenu!

  func applicationDidFinishLaunching(_ notification: Notification) {
    installMainMenu()
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let image = NSImage(systemSymbolName: "arrow.up.right.circle.fill", accessibilityDescription: "Caret") {
      image.isTemplate = true
      statusItem.button?.image = image
    } else {
      statusItem.button?.title = "↗"
    }
    menu = NSMenu()
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
    loginItem = NSMenuItem(title: "Launch Caret at login", action: #selector(toggleLogin), keyEquivalent: "")
    loginItem.target = self
    menu.addItem(loginItem)
    menu.addItem(.separator())
    menu.addItem(withTitle: "Copy last state (debug)", action: #selector(copyState), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Diagnose focused field in 5 s (debug)", action: #selector(diagnose), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Open helper page", action: #selector(openHelper), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Open Accessibility settings", action: #selector(openAccessibility), keyEquivalent: "")
      .target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Caret", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    menu.delegate = self
    statusItem.menu = menu

    statusWindow.onOpenSettings = { [weak self] in self?.openAccessibility() }
    statusWindow.onQuit = { NSApp.terminate(nil) }
    controller.onStatus = { [weak self] text, attention in
      self?.statusLine.title = text
      self?.statusWindow.update(status: text, needsAttention: attention)
    }
    controller.start()
  }

  /// The Dock menu mirrors the status-bar menu, for laptops whose notch hides the menu-bar icon.
  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { menu }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    statusWindow.update(status: statusLine.title, needsAttention: true)
    return true
  }

  /// A regular app needs a main menu; the Edit menu makes Cmd-C/V/X/A work in the preview window.
  private func installMainMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit Caret", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)
    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    main.addItem(editItem)
    NSApp.mainMenu = main
  }

  @objc private func togglePause() {
    Settings.paused.toggle()
    controller.pausedChanged()
  }
  @objc private func toggleContext() { Settings.screenContext.toggle() }
  @objc private func toggleLogin() {
    do {
      try HelperLauncher.setLaunchAtLogin(!HelperLauncher.launchesAtLogin)
    } catch {
      statusWindow.update(status: "Could not change login item: \(error.localizedDescription)", needsAttention: true)
    }
  }

  func applicationWillTerminate(_ notification: Notification) { controller.launcher.stop() }
  @objc private func copyState() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(controller.lastStateJSON, forType: .string)
  }
  @objc private func diagnose() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { Diagnostics.dumpFocusedElement() }
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
    loginItem.state = HelperLauncher.launchesAtLogin ? .on : .off
  }
}
