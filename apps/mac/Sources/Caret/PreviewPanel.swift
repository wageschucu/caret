import AppKit

/// The one activating window: exact preview, missing-slot fields, confirm/cancel.
/// Enter confirms only here. Esc cancels.
final class PreviewPanel: NSPanel, NSWindowDelegate {
  var onSubmit: ([String: String]) -> Void = { _ in }
  var onCancel: () -> Void = {}
  var onUndo: () -> Void = {}
  private var fields: [String: NSTextField] = [:]
  private let stack = NSStackView()

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 320), styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered, defer: false)
    title = "Caret"
    titlebarAppearsTransparent = true
    level = .floating
    isReleasedWhenClosed = false
    collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    delegate = self
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 36, left: 18, bottom: 16, right: 18)
    contentView = stack
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    onCancel()
    return true
  }

  override func cancelOperation(_ sender: Any?) { onCancel() }

  private func reset() {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    fields = [:]
  }

  private func heading(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
    return label
  }

  private func muted(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.textColor = .secondaryLabelColor
    label.font = NSFont.systemFont(ofSize: 11)
    label.preferredMaxLayoutWidth = 484
    return label
  }

  private func block(_ text: String, mono: Bool) -> NSScrollView {
    let view = NSTextView()
    view.isEditable = false
    view.string = text
    view.font = mono ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) : NSFont.systemFont(ofSize: 13)
    view.textContainerInset = NSSize(width: 6, height: 6)
    view.backgroundColor = NSColor.textBackgroundColor
    view.isVerticallyResizable = true
    view.textContainer?.widthTracksTextView = true
    let scroll = NSScrollView()
    scroll.documentView = view
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.widthAnchor.constraint(equalToConstant: 484).isActive = true
    scroll.heightAnchor.constraint(equalToConstant: min(160, max(44, CGFloat(text.split(separator: "\n").count) * 18 + 16)))
      .isActive = true
    return scroll
  }

  func showPreview(_ execution: HelperClient.Execution, label: String) {
    reset()
    stack.addArrangedSubview(heading("A quick look before we continue."))
    stack.addArrangedSubview(muted(label))
    if execution.demo { stack.addArrangedSubview(muted("Demo result · limited examples, local actions only.")) }
    if let preview = execution.preview, !preview.isEmpty { stack.addArrangedSubview(block(preview, mono: false)) }
    for call in execution.calls {
      let tool = call["tool"] as? String ?? ""
      let args = call["args"] ?? [:]
      let json = (try? JSONSerialization.data(withJSONObject: args, options: [.prettyPrinted, .sortedKeys]))
        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
      stack.addArrangedSubview(block(tool + "\n" + json, mono: true))
    }
    for slot in execution.missingSlots {
      let field = NSTextField(string: "")
      field.placeholderString = slot == "start" || slot == "end" ? "2026-09-25T10:00:00+02:00" : slot
      field.translatesAutoresizingMaskIntoConstraints = false
      field.widthAnchor.constraint(equalToConstant: 484).isActive = true
      let label = NSTextField(labelWithString: slot)
      label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
      stack.addArrangedSubview(label)
      stack.addArrangedSubview(field)
      fields[slot] = field
    }
    let primaryTitle =
      !execution.missingSlots.isEmpty
      ? "Update preview" : execution.requiresConfirmation ? "Confirm action" : "Continue"
    let primary = NSButton(title: primaryTitle, target: self, action: #selector(submit))
    primary.keyEquivalent = "\r"
    primary.bezelStyle = .rounded
    let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
    cancel.keyEquivalent = "\u{1b}"
    cancel.bezelStyle = .rounded
    let row = NSStackView(views: [primary, cancel])
    row.orientation = .horizontal
    stack.addArrangedSubview(row)
    present()
    if let first = execution.missingSlots.first, let field = fields[first] { makeFirstResponder(field) }
  }

  /// Result of a side-effecting action. Text results are inserted at the caret instead and never come here.
  func showDone(_ execution: HelperClient.Execution) {
    reset()
    stack.addArrangedSubview(heading("All set."))
    if execution.demo { stack.addArrangedSubview(muted("Demo result · local actions only.")) }
    stack.addArrangedSubview(block(execution.result ?? "", mono: false))
    let close = NSButton(title: "Close", target: self, action: #selector(cancelPressed))
    close.keyEquivalent = "\r"
    close.bezelStyle = .rounded
    var buttons = [close]
    if execution.undoID != nil {
      let undo = NSButton(title: "Undo", target: self, action: #selector(undoPressed))
      undo.bezelStyle = .rounded
      buttons.append(undo)
    }
    let row = NSStackView(views: buttons)
    row.orientation = .horizontal
    stack.addArrangedSubview(row)
    present()
  }

  func showError(_ message: String) {
    reset()
    stack.addArrangedSubview(heading("Something needs attention."))
    stack.addArrangedSubview(block(message, mono: false))
    let close = NSButton(title: "Close", target: self, action: #selector(cancelPressed))
    close.keyEquivalent = "\r"
    close.bezelStyle = .rounded
    stack.addArrangedSubview(close)
    present()
  }

  private func present() {
    stack.layoutSubtreeIfNeeded()
    let size = stack.fittingSize
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
    setFrame(
      NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height),
      display: true)
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
  }

  @objc private func submit() {
    var values: [String: String] = [:]
    for (name, field) in fields { values[name] = field.stringValue }
    onSubmit(values)
  }

  @objc private func cancelPressed() { onCancel() }
  @objc private func undoPressed() { onUndo() }
}
