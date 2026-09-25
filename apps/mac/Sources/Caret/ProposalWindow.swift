import AppKit

/// Editor for a proposed SKILL.md. The user reviews the draft, edits the markdown, and saves; the
/// helper validates it, forces trust to "reviewed", and hot-reloads the registry.
@MainActor
final class ProposalWindow: NSPanel {
  var onSave: (String) -> Void = { _ in }
  var onCancel: () -> Void = {}
  private let editor = NSTextView()
  private let heading = NSTextField(labelWithString: "")
  private let note = NSTextField(wrappingLabelWithString: "")
  private let saveButton = NSButton(title: "Save skill", target: nil, action: nil)

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
      styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
    title = "Caret — new skill"
    level = .floating
    isReleasedWhenClosed = false
    collectionBehavior = [.moveToActiveSpace]
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
    heading.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
    stack.addArrangedSubview(heading)
    note.font = NSFont.systemFont(ofSize: 11)
    note.textColor = .secondaryLabelColor
    note.preferredMaxLayoutWidth = 600
    note.stringValue =
      "Review and edit. The description is what the router reads (intent only, never a completeness condition). Saved skills run with a preview and confirmation until you edit trust in the file."
    stack.addArrangedSubview(note)
    editor.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    editor.isRichText = false
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false
    editor.allowsUndo = true
    let scroll = NSScrollView()
    scroll.documentView = editor
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.widthAnchor.constraint(equalToConstant: 604).isActive = true
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.isVerticallyResizable = true
    stack.addArrangedSubview(scroll)
    saveButton.target = self
    saveButton.action = #selector(save)
    saveButton.bezelStyle = .rounded
    saveButton.keyEquivalent = "s"
    saveButton.keyEquivalentModifierMask = [.command]
    let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
    cancel.bezelStyle = .rounded
    cancel.keyEquivalent = "\u{1b}"
    let row = NSStackView(views: [saveButton, cancel, NSTextField(labelWithString: "⌘S saves · Esc cancels")])
    row.orientation = .horizontal
    stack.addArrangedSubview(row)
    contentView = stack
  }

  override var canBecomeKey: Bool { true }
  override func cancelOperation(_ sender: Any?) { onCancel() }

  func show(markdown: String, label: String, demo: Bool) {
    heading.stringValue = "Create a skill: \(label)"
    if demo { heading.stringValue += " (template — no executor model configured)" }
    editor.string = markdown
    saveButton.isEnabled = true
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
    setFrame(NSRect(x: screen.midX - 320, y: screen.midY - 280, width: 640, height: 560), display: true)
    orderFrontRegardless()
    makeKey()
    makeFirstResponder(editor)
  }

  func showError(_ message: String) {
    note.stringValue = "Could not save: \(message)"
    note.textColor = .systemRed
    saveButton.isEnabled = true
  }

  @objc private func save() {
    saveButton.isEnabled = false
    onSave(editor.string)
  }
  @objc private func cancelPressed() { onCancel() }
}
