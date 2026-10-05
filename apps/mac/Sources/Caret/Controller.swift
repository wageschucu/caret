import AppKit

/// Orchestrates: keystroke → read focused field → ghost text + routing → overlay → accept → preview → execute.
/// Mirrors the state machine in public/app.js so both hosts behave the same.
@MainActor
final class Controller {
  /// Status line for the menu. `attention` is true only when the user must act (permission, helper down).
  var onStatus: (String, Bool) -> Void = { _, _ in }
  private func status(_ text: String, attention: Bool = false) { onStatus(text, attention) }

  private static func isConnectionFailure(_ error: Error) -> Bool {
    guard let code = (error as? URLError)?.code else { return false }
    return [.cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .timedOut].contains(code)
  }

  /// Cancellations from typing on are normal, not failures.
  private static func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
  }
  private(set) var lastStateJSON = "{}"

  private let reader = AccessibilityReader()
  private let tap = KeyTap()
  private let overlay = OverlayPanel()
  private let previewPanel = PreviewPanel()
  private let proposalWindow = ProposalWindow()
  let debugWindow = DebugWindow()
  private var canPropose = false
  private var variants: [String] = []
  private var variantIndex = 0
  private var styles: [HelperClient.StyleOption] = []
  private var styleIndex = 0
  private var client = HelperClient(base: Settings.helperURL)
  private let calendar = CalendarBridge()
  private let contacts = ContactsBridge()
  private let mail = MailBridge()
  let launcher = HelperLauncher()
  let localModels = LocalModelServer()
  /// Host-side undo for the last calendar event created through EventKit.
  private var calendarUndo: (helperID: String, eventID: String)?
  /// When composing in one of these, a draft replaces the typed instruction instead of opening a new window.
  private static let mailClients: Set<String> = [
    "com.apple.mail", "org.mozilla.thunderbird", "com.microsoft.Outlook", "com.readdle.smartemail-Mac",
    "com.airmail.airmail", "com.superhuman.electron",
  ]

  private var connected = false
  private var snapshot: FocusSnapshot?
  private var buffer = ""
  private var ghost = ""
  private var chips: [String] = []
  private var chosen = 0
  private var eventID: String?
  private var boundary = 0
  private var revision = 0
  private var lastTyped = Date()
  private var completionTask: Task<Void, Never>?
  private var routeTask: Task<Void, Never>?
  private var debounceTask: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var preview: HelperClient.Execution?
  private var previousApp: NSRunningApplication?
  private var slotAnswers: [String: String] = [:]
  private var busy = false
  /// The accept currently planning, so Esc can cancel it; the generation keeps a cancelled one from
  /// touching the state of a later accept.
  private var acceptTask: Task<Void, Never>?
  private var acceptGeneration = 0
  private var working: String?
  private var lastWarning: String?

  // MARK: - Lifecycle

  func start() {
    tap.onAction = { [weak self] action in self?.perform(action) }
    tap.passthrough = { [weak self] in self?.scheduleRefresh() }
    previewPanel.onSubmit = { [weak self] fields in self?.submitPreview(fields) }
    previewPanel.onCancel = { [weak self] in self?.cancelPreview() }
    previewPanel.onUndo = { [weak self] in self?.undo() }
    debugWindow.fetch = { [weak self] in try await self?.client.debug() ?? [:] }
    debugWindow.rollback = { [weak self] hash in
      guard let self else { return "" }
      let result = try await self.client.rollback(to: hash)
      _ = try? await self.client.bootstrap()
      return "Rolled back: \(result["skills"] ?? 0) skills active. Moved aside: \(result["moved_aside"] ?? "nothing")."
    }
    proposalWindow.onSave = { [weak self] markdown in self?.saveProposal(markdown) }
    proposalWindow.onCancel = { [weak self] in
      self?.proposalWindow.orderOut(nil)
      Task { await self?.returnFocus() }
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] _ in Task { @MainActor in self?.appSwitched() } }
    Task { await connect() }
    waitForTrust()
    mail.refreshInBackground()  // builds Caret's mail header index once; later refreshes are incremental
    // Recent-window capture: a page the user only reads never triggers a keystroke, so poll slowly.
    Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
      guard let self, Settings.screenContext, !Settings.paused else { return }
      let reader = self.reader
      self.axQueue.async { reader.captureFrontWindow() }
    }
  }

  private var promptedForTrust = false

  private func waitForTrust() {
    // Show the system prompt once; afterwards poll silently until the user flips the switch.
    let trusted = AccessibilityReader.isTrusted(prompt: !promptedForTrust)
    promptedForTrust = true
    if trusted {
      if tap.start() {
        status()
      } else {
        status("Could not install the key tap. Check Accessibility permission and relaunch.", attention: true)
      }
      return
    }
    status("Waiting for Accessibility permission… (if Caret is already listed, remove and re-add it)", attention: true)
    Task {
      try? await Task.sleep(for: .seconds(2))
      waitForTrust()
    }
  }

  private func connect() async {
    await localModels.startIfNeeded()  // once per run; the helper warms its models there
    do {
      let boot = try await client.bootstrap()
      connected = true
      var line = boot.mode == "demo" ? "Helper: demo routing" : "Helper: Jev live"
      if boot.executor == "demo" {
        line += ", demo executor"
      } else if let model = boot.executor_model {
        line += " · " + model.replacingOccurrences(of: "claude-", with: "")
        if let problem = boot.executor_fallback { line += " (local fallback: \(problem))" }
      }
      if let problems = boot.problems, !problems.isEmpty { line += " · \(problems.count) skill(s) skipped" }
      if let warning = boot.warning { line = "Demo routing · " + warning }
      status(line + (tap.isRunning ? "" : " · waiting for Accessibility"), attention: !tap.isRunning)
    } catch {
      connected = false
      if launcher.start() {
        status("Starting the helper…")
      } else if !launcher.attempted {
        status("Helper not running at \(Settings.helperURL.absoluteString) — start it with npm start", attention: true)
      } else if !launcher.isRunning {
        status("Helper could not be started; see ~/Library/Logs/Caret/helper.log", attention: true)
      }
      try? await Task.sleep(for: .seconds(launcher.isRunning ? 1 : 3))
      await connect()
    }
  }

  private func status() {
    if connected { Task { await connect() } } else { status("Accessibility granted · waiting for helper", attention: true) }
  }

  /// The helper address changed in Settings: drop the session and connect to the new one.
  func reconnect() {
    client = HelperClient(base: Settings.helperURL)
    connected = false
    launcher.reset()
    clearSuggestions()
    render()
    Task { await connect() }
  }

  func pausedChanged() {
    clearSuggestions()
    overlay.hide()
  }

  private func appSwitched() {
    clearSuggestions()
    overlay.hide()
    let reader = reader
    axQueue.async { reader.captureFrontWindow() }
    scheduleRefresh()
  }

  // MARK: - Reading the field

  private let axQueue = DispatchQueue(label: "caret.ax", qos: .userInteractive)
  private var readGeneration = 0

  private func scheduleRefresh() {
    refreshTask?.cancel()
    refreshTask = Task {
      try? await Task.sleep(for: .milliseconds(15))
      guard !Task.isCancelled else { return }
      refresh()
    }
  }

  /// Reads the focused field on a background queue; Accessibility calls into Chromium can take a while.
  private func refresh() {
    guard connected, preview == nil, !busy, !Settings.paused else { return }
    readGeneration += 1
    let generation = readGeneration
    let reader = reader
    axQueue.async {
      let current = reader.focused()
      DispatchQueue.main.async { [weak self] in
        guard let self, generation == self.readGeneration, self.preview == nil, !self.busy else { return }
        self.apply(current)
      }
    }
  }

  private func apply(_ current: FocusSnapshot?) {
    guard let current, !current.secure, !Settings.denyApps.contains(current.bundleID),
      current.bundleID != Bundle.main.bundleIdentifier
    else {
      snapshot = nil
      clearSuggestions()
      render()
      return
    }
    let sameField = snapshot.map { CFEqual($0.element, current.element) } ?? false
    if !sameField { Diagnostics.focus(current) }
    snapshot = current
    // Terminals and editors work line by line; prose works by paragraph.
    let newBuffer = current.buffer(lineOnly: !tabSafe)
    if sameField && newBuffer == buffer {
      render()
      return
    }
    buffer = newBuffer
    input()
  }

  /// State object for the helper, identical in shape to the browser host's.
  private func state() -> [String: Any] {
    guard let s = snapshot else { return ["buffer": buffer] }
    let screens: [[String: Any]] = s.recent.filter { $0.bundleID != s.bundleID || $0.windowTitle != s.windowTitle }
      .map {
        [
          "t": ISO8601DateFormatter().string(from: $0.timestamp), "app": $0.bundleID,
          "window_title": $0.windowTitle, "text": $0.text, "url": $0.url,
        ]
      }
    let focusedWindow = s.recent.last { $0.bundleID == s.bundleID && $0.windowTitle == s.windowTitle }?.text ?? ""
    let state: [String: Any] = [
      "buffer": buffer, "active_app": s.bundleID, "window_title": s.windowTitle, "url": NSNull(),
      "selection": s.selectedText, "focused_window": focusedWindow, "secure": s.secure,
      "paused": Settings.paused, "deny_apps": Settings.denyApps, "screens": screens,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
      lastStateJSON = String(data: data, encoding: .utf8) ?? "{}"
    }
    return state
  }

  // MARK: - Completion and routing (same sequence as app.js input())

  private func input() {
    revision += 1
    let v = revision
    lastTyped = Date()
    debounceTask?.cancel()
    routeTask?.cancel()
    completionTask?.cancel()
    ghost = ""
    if buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      chips = []
      let id = eventID
      eventID = nil
      render()
      Task { await client.dismiss(buffer: "", eventID: id) }
      return
    }
    render()
    if snapshot?.caretAtEnd == true { streamGhost(v) }
    if let last = buffer.last, ".!?;:\n".contains(last) {
      boundary += 1
      requestRoute(v)
    } else {
      debounceTask = Task {
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        requestRoute(v)
      }
    }
  }

  private func streamGhost(_ v: Int) {
    let state = state()
    completionTask = Task {
      var shown = false
      do {
        for try await chunk in client.complete(state: state) {
          guard v == revision, preview == nil else { return }
          ghost = chunk.text ?? ""
          render()
          if !ghost.isEmpty && !shown {
            shown = true
            client.telemetry("ghost_shown", eventID: eventID)
          }
          if chunk.phrase_boundary == true {
            boundary += 1
            debounceTask?.cancel()
            requestRoute(v)
          }
        }
      } catch {
        if v == revision, !Self.isCancellation(error) { status("Completer: \(error.localizedDescription)") }
      }
    }
  }

  private func requestRoute(_ v: Int) {
    routeTask?.cancel()
    let state = state()
    let boundary = boundary
    routeTask = Task {
      do {
        let result = try await client.route(state: state, boundary: boundary)
        guard v == revision, preview == nil else { return }
        chips = result.shown
        chosen = 0
        eventID = result.event_id
        canPropose = result.propose == true && chips.isEmpty
        updateVariants()
        render()
        if let warning = result.warning, warning != lastWarning {
          lastWarning = warning
          status("Demo routing · " + warning)
        }
        if !chips.isEmpty {
          client.telemetry("chip_rendered", eventID: eventID, latencyMs: Date().timeIntervalSince(lastTyped) * 1000)
        }
      } catch {
        guard v == revision, !Self.isCancellation(error) else { return }
        chips = []
        render()
        Diagnostics.log("route failed: \(error.localizedDescription)")
        if Self.isConnectionFailure(error) {
          // The helper died or was restarted: bring it back and reconnect.
          connected = false
          launcher.reset()
          status("Helper unreachable — restarting it")
          Task { await connect() }
        } else {
          status("Router: \(error.localizedDescription)")
        }
      }
    }
  }

  private func clearSuggestions() {
    revision += 1
    debounceTask?.cancel()
    routeTask?.cancel()
    completionTask?.cancel()
    ghost = ""
    chips = []
    canPropose = false
    variants = []
    variantIndex = 0
    styles = []
    styleIndex = 0
  }

  /// Destination options for the highlighted chip: the one named in the sentence first, then the
  /// user's home currencies, then the rest; the source currency in the sentence is left out.
  private func updateVariants() {
    variants = []
    variantIndex = 0
    styles = []
    styleIndex = 0
    if let slug = chips[safe: chosen], let options = client.skill(slug)?.styles, options.count > 1 {
      styles = options
      // The Settings value is the default selection; the pill choice applies to this accept only.
      styleIndex = options.firstIndex { $0.value == Settings.resultStyle } ?? 0
    }
    guard let slug = chips[safe: chosen], let skill = client.skill(slug), let all = skill.variants, all.count > 1
    else { return }
    let lower = buffer.lowercased()
    var mentioned: [String] = []
    for code in all where lower.range(of: "\\b" + code.lowercased() + "\\b", options: .regularExpression) != nil {
      mentioned.append(code)
    }
    for (symbol, code) in [("$", "USD"), ("€", "EUR"), ("£", "GBP"), ("¥", "JPY")]
    where lower.contains(symbol) && !mentioned.contains(code) && all.contains(code) {
      mentioned.insert(code, at: 0)
    }
    // With two currencies named, the first is the source and the last the destination.
    let source = mentioned.first
    let stated = mentioned.count > 1 ? mentioned.last : nil
    let home = (Settings.profile["currencies"] ?? "").uppercased()
      .split(whereSeparator: { ", ;".contains($0) }).map(String.init).filter { all.contains($0) }
    var ordered: [String] = []
    for code in [stated].compactMap({ $0 }) + home + all where !ordered.contains(code) && code != source {
      ordered.append(code)
    }
    variants = ordered
  }

  private var tabSafe: Bool { !(snapshot.map { Settings.tabUnsafeApps.contains($0.bundleID) } ?? false) }
  private var acceptKeyName: String { tabSafe ? "Tab" : "⌃Space" }

  private func syncKeyState() {
    tap.state = KeyTap.State(
      active: snapshot != nil && preview == nil && !busy, hasGhost: !ghost.isEmpty, chipCount: chips.count,
      tabSafe: tabSafe, canPropose: canPropose, variantCount: variants.count, styleCount: styles.count,
      planning: acceptTask != nil)
  }

  private func render() {
    syncKeyState()
    guard let s = snapshot, preview == nil else {
      overlay.hide()
      return
    }
    let anchor = s.caretRect ?? s.frame.map { CGRect(x: $0.minX, y: $0.minY, width: 1, height: 1) }
    guard let anchor else {
      overlay.hide()
      return
    }
    overlay.show(
      ghost: ghost,
      chips: chips.enumerated().map { (label: client.label(for: $0.element), selected: $0.offset == chosen) },
      acceptKey: acceptKeyName, anchor: anchor, working: working.map { acceptTask != nil ? $0 + "   Esc cancels" : $0 },
      hint: canPropose ? "⌘⇧N  create a skill for this?" : nil,
      variants: variants.enumerated().map { (label: $0.element, selected: $0.offset == variantIndex) },
      styles: styles.enumerated().map { (label: $0.element.label, selected: $0.offset == styleIndex) })
  }

  // MARK: - Keys

  /// Actions the key tap already decided to swallow, delivered on the main thread.
  private func perform(_ action: KeyTap.Action) {
    if case .cancelPlanning = action {
      cancelPlanning()
      return
    }
    guard preview == nil, !busy, snapshot != nil else { return }
    switch action {
    case .dismiss: dismiss()
    case .accept: accept()
    case .ghostWord: insertGhost(wordOnly: true)
    case .cancelPlanning: break
    case .propose: proposeSkill()
    case .variant(let step):
      guard variants.count > 1 else { return }
      variantIndex = (variantIndex + step + variants.count) % variants.count
      render()
    case .style(let step):
      guard styles.count > 1 else { return }
      styleIndex = (styleIndex + step + styles.count) % styles.count
      render()
    case .cycle(let step):
      guard chips.count > 1 else { return }
      chosen = (chosen + step + chips.count) % chips.count
      updateVariants()
      render()
      client.telemetry("cycle", eventID: eventID)
    }
  }

  private func dismiss() {
    let id = eventID
    let text = buffer
    clearSuggestions()
    render()
    Task { await client.dismiss(buffer: text, eventID: id) }
  }

  private func insertGhost(wordOnly: Bool) {
    guard !ghost.isEmpty else { return }
    var text = ghost
    if wordOnly, let match = ghost.range(of: #"^\s*\S+\s*"#, options: .regularExpression) {
      text = String(ghost[match])
    }
    client.telemetry(wordOnly ? "ctrl_right" : "ghost_accepted", eventID: eventID)
    ghost = String(ghost.dropFirst(text.count))
    clearSuggestions()
    overlay.hide()
    AccessibilityReader.insert(text, into: snapshot?.element)
    scheduleRefresh()
  }

  private func accept() {
    if chips.isEmpty {
      insertGhost(wordOnly: false)
      return
    }
    guard let skill = chips[safe: chosen], let eventID else { return }
    // Read the pill choices before the overlay state is cleared.
    var fields: [String: String] = ["result_style": Settings.resultStyle]
    if let slot = client.skill(skill)?.variant_slot, !slot.isEmpty, let choice = variants[safe: variantIndex] {
      fields[slot] = choice
    }
    if let slot = client.skill(skill)?.style_slot, !slot.isEmpty, let choice = styles[safe: styleIndex] {
      fields[slot] = choice.value
    }
    busy = true
    clearSuggestions()
    working = client.label(for: skill) + "…"
    render()
    previousApp = NSWorkspace.shared.frontmostApplication
    acceptGeneration += 1
    let generation = acceptGeneration
    acceptTask = Task {
      do {
        // Skills that draft mail get the address-book matches for names in the sentence.
        if client.skill(skill)?.allowed_tools?.contains("mail.draft") == true {
          // Inside a mail client the draft is written in place; recipient and subject are already there.
          if let app = snapshot?.bundleID, Self.mailClients.contains(app) { fields["in_mail_client"] = "true" }
          let names = ContactsBridge.names(in: buffer)
          let matches = await contacts.lookup(names)
          if !matches.isEmpty { fields["contacts"] = matches.joined(separator: "\n") }
          // Tell the helper which names were checked, so it need not ask again for the same ones.
          if !names.isEmpty { fields["contacts_checked"] = names.joined(separator: "|") }
        }
        slotAnswers = fields
        let label = client.label(for: skill)
        let progress: (String) -> Void = { [weak self] text in
          Task { @MainActor in
            guard let self, generation == self.acceptGeneration else { return }  // cancelled meanwhile
            self.working = "\(label): \(text)…"
            self.render()
          }
        }
        var execution = try await client.prepare(
          eventID: eventID, skill: skill, buffer: buffer, fields: fields, previous: nil, onProgress: progress)
        // The executor may ask for host-side lookups (Contacts) before it can plan; answer and resume.
        var rounds = 0
        while execution.status == "needs", rounds < 3 {
          rounds += 1
          var lookups = execution.obtained
          for need in execution.needs {
            guard let tool = need["tool"] as? String, let args = need["args"] as? [String: Any] else { continue }
            var result = "Lookup not available on this host"
            if tool == "contacts.lookup", let name = args["name"] as? String {
              let matches = await contacts.lookup([name])
              result = matches.isEmpty ? "No contacts match “\(name)”" : matches.joined(separator: "\n")
            } else if tool == "mail.search", let query = args["query"] as? String {
              do {
                result = try await mail.search(query)
              } catch {
                result = "Mail search failed: \(error.localizedDescription)"
              }
            } else if tool == "calendar.freebusy", let from = args["from"] as? String, let to = args["to"] as? String {
              do {
                result = try await calendar.freeBusy(from: from, to: to)
              } catch {
                result = "Calendar lookup failed: \(error.localizedDescription)"
              }
            }
            lookups.append(["tool": tool, "args": args, "result": result])
          }
          try Task.checkCancellation()
          working = client.label(for: skill) + "… (looking up)"
          render()
          execution = try await client.prepare(
            eventID: eventID, skill: skill, buffer: buffer, fields: fields, previous: nil, lookups: lookups,
            final: rounds >= 2, onProgress: progress)  // last round: finish with what has been gathered
        }
        try Task.checkCancellation()
        // Planning is done: from here the preview or the host tool owns the keys, not the cancel.
        if generation == acceptGeneration {
          acceptTask = nil
          render()
        }
        if execution.status == "needs" {
          previewPanel.showError("Caret could not finish this after several lookups. Try a more specific sentence.")
        } else {
          await show(execution)
        }
      } catch where Task.isCancelled || Self.isCancellation(error) {
        Diagnostics.log("prepare cancelled for \(skill)")
      } catch {
        Diagnostics.log("prepare failed for \(skill): \(error.localizedDescription)")
        previewPanel.showError(error.localizedDescription)
      }
      guard generation == acceptGeneration else { return }  // cancelled; a later accept owns the state
      acceptTask = nil
      busy = false
      working = nil
      render()
      syncKeyState()
    }
    render()  // shows "Esc cancels" and lets the key tap take Esc
  }

  /// Esc while a skill is planning: stop it. Closing the request makes the helper abort the model call
  /// and log the cancel; nothing is executed or shown, and the typed text stays as it was.
  private func cancelPlanning() {
    guard let task = acceptTask else { return }
    task.cancel()
    acceptTask = nil
    acceptGeneration += 1
    busy = false
    working = nil
    render()
    syncKeyState()
  }

  // MARK: - Skill proposals (spec §7.4)

  private func proposeSkill() {
    guard canPropose, let eventID, !busy else { return }
    busy = true
    working = "Drafting a skill…"
    clearSuggestions()
    render()
    previousApp = NSWorkspace.shared.frontmostApplication
    Task {
      do {
        let draft = try await client.propose(eventID: eventID)
        working = nil
        render()
        proposalWindow.show(markdown: draft.markdown, label: draft.label, demo: draft.demo == true)
      } catch {
        working = nil
        render()
        previewPanel.showError(error.localizedDescription)
      }
      busy = false
      syncKeyState()
    }
  }

  private func saveProposal(_ markdown: String) {
    Task {
      do {
        let saved = try await client.createSkill(markdown: markdown)
        proposalWindow.orderOut(nil)
        _ = try? await client.bootstrap()  // refresh labels; the helper reloaded the registry already
        previewPanel.showNotice(
          "Skill “\(saved.label ?? saved.slug)” added. It shows a preview and asks for confirmation until you change trust in skills/\(saved.slug)/SKILL.md. Type the sentence again to try it.")
      } catch {
        proposalWindow.showError(error.localizedDescription)
      }
    }
  }

  // MARK: - Preview and execution

  private func show(_ execution: HelperClient.Execution) async {
    if execution.status == "host_execute" {
      await performHostTool(execution)
      return
    }
    if execution.status == "preview" {
      preview = execution
      syncKeyState()
      previewPanel.showPreview(execution, label: client.label(for: execution.skill), buffer: buffer)
      return
    }
    preview = nil
    let effect = client.skill(execution.skill)?.side_effect_class ?? "preview-only"
    if effect == "preview-only", let result = execution.result {
      // Text results replace the typed intent, after focus returns to the field.
      previewPanel.orderOut(nil)
      await returnFocus()
      AccessibilityReader.replaceBeforeCaret(length: buffer.utf16.count, with: result, in: snapshot)
      actedOn(result, skill: execution.skill)
      scheduleRefresh()
    } else {
      calendarUndo = nil
      lastUndoID = execution.undoID
      previewPanel.showDone(execution)
    }
  }

  /// The helper validated (and, where required, consumed the confirmation); the host now performs
  /// the tool and reports the outcome.
  private func performHostTool(_ execution: HelperClient.Execution) async {
    preview = nil
    syncKeyState()
    guard let id = execution.id, let call = execution.calls.first, let tool = call["tool"] as? String,
      let args = call["args"] as? [String: Any]
    else {
      previewPanel.showError("The helper handed off an action this host cannot perform.")
      return
    }
    do {
      switch tool {
      case "calendar.create":
        guard let title = args["title"] as? String, let start = args["start"] as? String,
          let end = args["end"] as? String
        else { throw CalendarBridge.BridgeError(message: "Incomplete calendar event.") }
        let created = try await calendar.create(title: title, start: start, end: end)
        calendarUndo = (id, created.identifier)
        lastUndoID = nil
        try? await client.reportHostExecution(id: id, ok: true)
        previewPanel.showDone(
          HelperClient.Execution(
            status: "done", id: id, skill: execution.skill, preview: nil, missingSlots: [], calls: [],
            requiresConfirmation: false, demo: false,
            result: "Added “\(title)” to your “\(created.calendar)” calendar. No invitations were sent.",
            undoID: "host:" + created.identifier, needs: [], obtained: []))
      case "url.open":
        guard let raw = args["url"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? "")
        else { throw CalendarBridge.BridgeError(message: "Not a web address.") }
        NSWorkspace.shared.open(url)
        try? await client.reportHostExecution(id: id, ok: true)
      case "mail.draft":
        guard let subject = args["subject"] as? String, let body = args["body"] as? String else {
          throw CalendarBridge.BridgeError(message: "Incomplete mail draft.")
        }
        let to = (args["to"] as? String) ?? ""
        if let app = snapshot?.bundleID, Self.mailClients.contains(app) {
          // Already composing: the draft body replaces the typed instruction in place.
          previewPanel.orderOut(nil)
          await returnFocus()
          AccessibilityReader.replaceBeforeCaret(length: buffer.utf16.count, with: body, in: snapshot)
          actedOn(body, skill: execution.skill)
          scheduleRefresh()
        } else {
          var parts = URLComponents()
          parts.scheme = "mailto"
          parts.path = to.replacingOccurrences(of: " ", with: "")
          parts.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
          guard let url = parts.url else { throw CalendarBridge.BridgeError(message: "Could not build the draft.") }
          NSWorkspace.shared.open(url)
        }
        try? await client.reportHostExecution(id: id, ok: true)
      default:
        throw CalendarBridge.BridgeError(message: "This host cannot perform \(tool).")
      }
    } catch {
      Diagnostics.log("\(tool) failed: \(error.localizedDescription)")
      try? await client.reportHostExecution(id: id, ok: false, error: error.localizedDescription)
      previewPanel.showError(error.localizedDescription)
    }
  }

  /// The skill just rewrote the sentence: keep its chip away for the resulting text until the user
  /// types something substantially new or ends the phrase. The new buffer is the result itself,
  /// since the intent (the whole current paragraph before the caret) was replaced by it.
  private func actedOn(_ result: String, skill: String) {
    let id = eventID
    Task { await client.dismiss(buffer: result, eventID: id, skills: [skill]) }
  }

  private func submitPreview(_ fields: [String: String]) {
    guard let p = preview, !busy else { return }
    busy = true
    working = client.label(for: p.skill) + "…"
    Task {
      do {
        if !p.missingSlots.isEmpty {
          slotAnswers.merge(fields) { _, new in new }
          if p.missingSlots.contains(where: { (slotAnswers[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw HelperClient.HelperError(message: "Fill in each missing detail.")
          }
          guard let eventID, let id = p.id else { return }
          let next = try await client.prepare(
            eventID: eventID, skill: p.skill, buffer: buffer, fields: slotAnswers, previous: id)
          await show(next)
        } else if let id = p.id {
          await show(try await client.confirm(id: id))
        }
      } catch {
        Diagnostics.log("preview submit failed: \(error.localizedDescription)")
        previewPanel.showError(error.localizedDescription)
        preview = nil
      }
      busy = false
      working = nil
      render()
    }
  }

  private func cancelPreview() {
    let p = preview
    preview = nil
    slotAnswers = [:]
    syncKeyState()
    previewPanel.orderOut(nil)
    if let id = p?.id, p?.status == "preview" { Task { await client.cancel(id: id) } }
    Task { await returnFocus() }
  }

  private var lastUndoID: String?

  private func undo() {
    if let pending = calendarUndo {
      Task {
        do {
          try await calendar.delete(identifier: pending.eventID)
          calendarUndo = nil
          try? await client.reportHostExecution(id: pending.helperID, ok: true, undone: true)
          previewPanel.showNotice("Undone. The event was removed from your calendar.")
        } catch {
          previewPanel.showError(error.localizedDescription)
        }
      }
      return
    }
    guard let id = lastUndoID else {
      previewPanel.showError("Nothing to undo.")
      return
    }
    Task {
      do {
        try await client.undo(id: id)
        lastUndoID = nil
        previewPanel.showNotice("Undone. The record was removed.")
      } catch {
        previewPanel.showError(error.localizedDescription)
      }
    }
  }

  /// The preview is a non-activating panel, so the host app normally stays active. Re-activate it
  /// only if something else took over meanwhile.
  private func returnFocus() async {
    if let app = previousApp, NSWorkspace.shared.frontmostApplication != app {
      app.activate()
      try? await Task.sleep(for: .milliseconds(120))
    }
  }
}

extension Array {
  subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
