import AppKit

/// Settings: helper address, context toggle, deny list, Tab-safe apps, launch at login.
/// Changes apply immediately; nothing here needs `defaults write`.
@MainActor
final class SettingsWindow: NSPanel {
  var onHelperURLChanged: () -> Void = {}
  private let helperField = NSTextField(string: "")
  private let contextBox = NSButton(checkboxWithTitle: "Include recent windows as context (summarize / extract action items)", target: nil, action: nil)
  private let loginBox = NSButton(checkboxWithTitle: "Launch Caret at login", target: nil, action: nil)
  private let denyView = NSTextView()
  private let tabView = NSTextView()
  private let nameField = NSTextField(string: "")
  private let emailField = NSTextField(string: "")
  private let signatureField = NSTextField(string: "")
  private let currenciesField = NSTextField(string: "")
  private let stylePopup = NSPopUpButton()
  private let notesView = NSTextView()

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
      styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
    title = "Caret Settings"
    level = .floating
    isReleasedWhenClosed = false
    collectionBehavior = [.moveToActiveSpace]

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

    stack.addArrangedSubview(label("Helper address", bold: true))
    helperField.placeholderString = "http://127.0.0.1:4317"
    helperField.target = self
    helperField.action = #selector(helperChanged)
    fixWidth(helperField)
    stack.addArrangedSubview(helperField)

    contextBox.target = self
    contextBox.action = #selector(contextChanged)
    stack.addArrangedSubview(contextBox)
    loginBox.target = self
    loginBox.action = #selector(loginChanged)
    stack.addArrangedSubview(loginBox)

    stack.addArrangedSubview(label("About you — used when drafting (name, sign-off, address). Never sent to the router.", bold: true))
    for (field, placeholder) in [
      (nameField, "Name"), (emailField, "Email address"), (signatureField, "Sign-off, e.g. “Best, Paul”"),
      (currenciesField, "Home currencies in order, e.g. CHF, USD"),
    ] {
      field.placeholderString = placeholder
      field.target = self
      field.action = #selector(profileChanged)
      fixWidth(field)
      stack.addArrangedSubview(field)
    }
    notesView.font = NSFont.systemFont(ofSize: 12)
    notesView.isRichText = false
    notesView.delegate = self
    let notesScroll = NSScrollView()
    notesScroll.documentView = notesView
    notesScroll.borderType = .bezelBorder
    notesScroll.hasVerticalScroller = true
    notesScroll.translatesAutoresizingMaskIntoConstraints = false
    notesScroll.widthAnchor.constraint(equalToConstant: 520).isActive = true
    notesScroll.heightAnchor.constraint(equalToConstant: 56).isActive = true
    notesView.autoresizingMask = [.width]
    notesView.textContainer?.widthTracksTextView = true
    stack.addArrangedSubview(label("Notes for drafts: role, company, preferred language, tone…", bold: false))
    stack.addArrangedSubview(notesScroll)

    stack.addArrangedSubview(label("Result style for conversions", bold: true))
    stylePopup.addItems(withTitles: ["Converted amount only, e.g. 264.70 EUR", "Full line with source and rate"])
    stylePopup.target = self
    stylePopup.action = #selector(styleChanged)
    stack.addArrangedSubview(stylePopup)

    stack.addArrangedSubview(label("Never read these apps (one bundle identifier per line)", bold: true))
    stack.addArrangedSubview(editor(denyView, action: #selector(addDenyApp)))
    stack.addArrangedSubview(label("Apps where Tab is native — Caret uses Ctrl-Space there", bold: true))
    stack.addArrangedSubview(editor(tabView, action: #selector(addTabApp)))

    let hint = label(
      "Bundle identifiers look like com.apple.mail. “Add app…” picks one from /Applications. Lists are saved as you type.",
      bold: false)
    hint.textColor = .secondaryLabelColor
    hint.font = NSFont.systemFont(ofSize: 11)
    stack.addArrangedSubview(hint)
    let close = NSButton(title: "Close", target: self, action: #selector(closePressed))
    close.keyEquivalent = "\u{1b}"
    close.bezelStyle = .rounded
    stack.addArrangedSubview(close)
    contentView = stack
  }

  override var canBecomeKey: Bool { true }

  private func label(_ text: String, bold: Bool) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = bold ? NSFont.systemFont(ofSize: 12, weight: .semibold) : NSFont.systemFont(ofSize: 12)
    field.preferredMaxLayoutWidth = 520
    return field
  }

  private func fixWidth(_ view: NSView) {
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalToConstant: 520).isActive = true
  }

  private func editor(_ view: NSTextView, action: Selector) -> NSView {
    view.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    view.isRichText = false
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.delegate = self
    let scroll = NSScrollView()
    scroll.documentView = view
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.widthAnchor.constraint(equalToConstant: 430).isActive = true
    scroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
    view.autoresizingMask = [.width]
    view.textContainer?.widthTracksTextView = true
    let add = NSButton(title: "Add app…", target: self, action: action)
    add.bezelStyle = .rounded
    let row = NSStackView(views: [scroll, add])
    row.orientation = .horizontal
    row.alignment = .top
    return row
  }

  func present() {
    helperField.stringValue = Settings.helperURL.absoluteString
    contextBox.state = Settings.screenContext ? .on : .off
    loginBox.state = HelperLauncher.launchesAtLogin ? .on : .off
    denyView.string = Settings.denyApps.joined(separator: "\n")
    tabView.string = Settings.tabUnsafeApps.joined(separator: "\n")
    let profile = Settings.profile
    nameField.stringValue = profile["name"] ?? ""
    emailField.stringValue = profile["email"] ?? ""
    signatureField.stringValue = profile["signature"] ?? ""
    notesView.string = profile["notes"] ?? ""
    currenciesField.stringValue = profile["currencies"] ?? ""
    stylePopup.selectItem(at: Settings.resultStyle == "verbose" ? 1 : 0)
    center()
    orderFrontRegardless()
    makeKey()
  }

  private func lines(_ view: NSTextView) -> [String] {
    view.string.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  private func pickApp(into view: NSTextView) {
    let panel = NSOpenPanel()
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.allowedContentTypes = [.applicationBundle]
    panel.allowsMultipleSelection = true
    panel.message = "Choose an application"
    guard panel.runModal() == .OK else { return }
    var current = lines(view)
    for url in panel.urls {
      if let id = Bundle(url: url)?.bundleIdentifier, !current.contains(id) { current.append(id) }
    }
    view.string = current.joined(separator: "\n")
    textDidChange(Notification(name: NSText.didChangeNotification, object: view))
  }

  @objc private func helperChanged() {
    guard let url = URL(string: helperField.stringValue), url.scheme != nil, url.host != nil else { return }
    UserDefaults.standard.set(url.absoluteString, forKey: "helperURL")
    onHelperURLChanged()
  }
  @objc private func profileChanged() {
    Settings.profile = [
      "name": nameField.stringValue, "email": emailField.stringValue, "signature": signatureField.stringValue,
      "notes": notesView.string, "currencies": currenciesField.stringValue,
    ]
  }
  @objc private func styleChanged() { Settings.resultStyle = stylePopup.indexOfSelectedItem == 1 ? "verbose" : "compact" }
  @objc private func contextChanged() { Settings.screenContext = contextBox.state == .on }
  @objc private func loginChanged() {
    do {
      try HelperLauncher.setLaunchAtLogin(loginBox.state == .on)
    } catch {
      loginBox.state = HelperLauncher.launchesAtLogin ? .on : .off
    }
  }
  @objc private func addDenyApp() { pickApp(into: denyView) }
  @objc private func addTabApp() { pickApp(into: tabView) }
  @objc private func closePressed() { orderOut(nil) }
}

extension SettingsWindow: NSTextViewDelegate {
  func textDidChange(_ notification: Notification) {
    guard let view = notification.object as? NSTextView else { return }
    if view === denyView {
      Settings.denyApps = lines(view)
    } else if view === tabView {
      Settings.tabUnsafeApps = lines(view)
    } else if view === notesView {
      profileChanged()
    }
  }
}
