import AppKit

/// A small window shown while Caret needs attention (no Accessibility grant, no helper).
/// Exists because menu-bar icons can be hidden by the notch on laptop displays.
@MainActor
final class StatusWindow: NSPanel {
  private let label = NSTextField(wrappingLabelWithString: "")
  var onOpenSettings: () -> Void = {}
  var onQuit: () -> Void = {}

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 160), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    title = "Caret"
    level = .floating
    isReleasedWhenClosed = false
    collectionBehavior = [.moveToActiveSpace]
    label.preferredMaxLayoutWidth = 380
    label.font = NSFont.systemFont(ofSize: 13)
    let settings = NSButton(title: "Open Accessibility settings", target: self, action: #selector(openSettings))
    settings.bezelStyle = .rounded
    let quit = NSButton(title: "Quit Caret", target: self, action: #selector(quit))
    quit.bezelStyle = .rounded
    let buttons = NSStackView(views: [settings, quit])
    buttons.orientation = .horizontal
    let hint = NSTextField(
      wrappingLabelWithString:
        "Caret also lives in the menu bar as a circled arrow. On laptops with a notch that icon can be hidden; this window appears instead whenever Caret needs attention.")
    hint.font = NSFont.systemFont(ofSize: 11)
    hint.textColor = .secondaryLabelColor
    hint.preferredMaxLayoutWidth = 380
    let stack = NSStackView(views: [label, buttons, hint])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
    contentView = stack
  }

  func update(status: String, needsAttention: Bool) {
    label.stringValue = status
    if needsAttention {
      if !isVisible {
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
      }
    } else {
      orderOut(nil)
    }
  }

  @objc private func openSettings() { onOpenSettings() }
  @objc private func quit() { onQuit() }
}
