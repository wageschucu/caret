import AppKit

/// The preview: exact action, missing-slot fields, confirm/cancel. A non-activating key panel.
/// Enter confirms only here. Esc cancels.
final class PreviewPanel: NSPanel, NSWindowDelegate {
  var onSubmit: ([String: String]) -> Void = { _ in }
  var onCancel: () -> Void = {}
  var onUndo: () -> Void = {}
  private var fields: [String: NSTextField] = [:]
  private var pickers: [String: NSDatePicker] = [:]
  private let stack = NSStackView()
  private static let iso: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
    return f
  }()

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
      styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered, defer: false)
    title = "Caret"
    titlebarAppearsTransparent = true
    // Takes keyboard focus without activating Caret, which macOS 14+ would refuse anyway
    // for an app the user did not just launch. The host app stays active underneath.
    level = .floating
    becomesKeyOnlyIfNeeded = false
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    delegate = self
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 36, left: 18, bottom: 16, right: 18)
    contentView = stack
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    onCancel()
    return true
  }

  override func cancelOperation(_ sender: Any?) { onCancel() }

  private func reset() {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    fields = [:]
    pickers = [:]
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

  /// Sensible defaults for slots, derived from the typed sentence so Enter alone can accept them.
  static func defaults(for slots: [String], buffer: String) -> (dates: [String: Date], texts: [String: String]) {
    var dates: [String: Date] = [:]
    var texts: [String: String] = [:]
    let calendar = Calendar.current
    let lower = buffer.lowercased()
    var start: Date
    if lower.contains("tomorrow"), let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) {
      start = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    } else {
      let next = Date().addingTimeInterval(3600)
      start = calendar.date(bySetting: .minute, value: 0, of: next) ?? next
      start = calendar.date(bySetting: .second, value: 0, of: start) ?? start
    }
    if let match = lower.range(of: #"\bat (\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#, options: .regularExpression) {
      let parts = lower[match].replacingOccurrences(of: "at ", with: "").split(separator: ":")
      var hour = Int(parts.first?.prefix(while: \.isNumber) ?? "") ?? 10
      if lower[match].hasSuffix("pm"), hour < 12 { hour += 12 }
      start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: start) ?? start
    }
    if slots.contains("start") { dates["start"] = start }
    if slots.contains("end") { dates["end"] = start.addingTimeInterval(3600) }
    if slots.contains("title") {
      var title = buffer.replacingOccurrences(
        of: #"^\s*(schedule|create|plan|book|set up|add)\s+(a|an|the)?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
      title = title.replacingOccurrences(
        of: #"\s*\b(tomorrow|today|tonight|next \w+|on \w+|at \d.*)$"#, with: "", options: [.regularExpression, .caseInsensitive])
      title = title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
      if !title.isEmpty { texts["title"] = title.prefix(1).uppercased() + title.dropFirst() }
    }
    return (dates, texts)
  }

  func showPreview(_ execution: HelperClient.Execution, label: String, buffer: String = "") {
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
    let defaults = Self.defaults(for: execution.missingSlots, buffer: buffer)
    for slot in execution.missingSlots {
      let label = NSTextField(labelWithString: slot)
      label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
      stack.addArrangedSubview(label)
      if let date = defaults.dates[slot] {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.dateValue = date
        picker.sizeToFit()
        stack.addArrangedSubview(picker)
        pickers[slot] = picker
      } else {
        let field = NSTextField(string: defaults.texts[slot] ?? "")
        field.placeholderString = slot
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 484).isActive = true
        stack.addArrangedSubview(field)
        fields[slot] = field
      }
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
    if let first = execution.missingSlots.first {
      makeFirstResponder(fields[first] ?? pickers[first])
      fields[first]?.selectText(nil)
    }
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
    orderFrontRegardless()
    makeKey()
  }

  @objc private func submit() {
    var values: [String: String] = [:]
    for (name, field) in fields { values[name] = field.stringValue }
    for (name, picker) in pickers { values[name] = Self.iso.string(from: picker.dateValue) }
    onSubmit(values)
  }

  @objc private func cancelPressed() { onCancel() }
  @objc private func undoPressed() { onUndo() }
}
