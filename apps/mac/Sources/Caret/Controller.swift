import AppKit

/// Orchestrates: keystroke → read focused field → ghost text + routing → overlay → accept → preview → execute.
/// Mirrors the state machine in public/app.js so both hosts behave the same.
@MainActor
final class Controller {
  var onStatus: (String) -> Void = { _ in }
  private(set) var lastStateJSON = "{}"

  private let reader = AccessibilityReader()
  private let tap = KeyTap()
  private let overlay = OverlayPanel()
  private let previewPanel = PreviewPanel()
  private var client = HelperClient(base: Settings.helperURL)

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

  // MARK: - Lifecycle

  func start() {
    tap.onAction = { [weak self] action in self?.perform(action) }
    tap.passthrough = { [weak self] in self?.scheduleRefresh() }
    previewPanel.onSubmit = { [weak self] fields in self?.submitPreview(fields) }
    previewPanel.onCancel = { [weak self] in self?.cancelPreview() }
    previewPanel.onUndo = { [weak self] in self?.undo() }
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] _ in Task { @MainActor in self?.appSwitched() } }
    Task { await connect() }
    waitForTrust()
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
        onStatus("Could not install the key tap. Check Accessibility permission and relaunch.")
      }
      return
    }
    onStatus("Waiting for Accessibility permission… (if Caret is already listed, remove and re-add it)")
    Task {
      try? await Task.sleep(for: .seconds(2))
      waitForTrust()
    }
  }

  private func connect() async {
    do {
      let boot = try await client.bootstrap()
      connected = true
      var line = boot.mode == "demo" ? "Helper: demo routing" : "Helper: Jev live"
      if boot.executor == "demo" { line += ", demo executor" }
      if let problems = boot.problems, !problems.isEmpty { line += " · \(problems.count) skill(s) skipped" }
      onStatus(line + (tap.isRunning ? "" : " · waiting for Accessibility"))
    } catch {
      connected = false
      onStatus("Helper not running at \(Settings.helperURL.absoluteString) — retrying")
      try? await Task.sleep(for: .seconds(3))
      await connect()
    }
  }

  private func status() {
    if connected { Task { await connect() } } else { onStatus("Accessibility granted · waiting for helper") }
  }

  func pausedChanged() {
    clearSuggestions()
    overlay.hide()
  }

  private func appSwitched() {
    clearSuggestions()
    overlay.hide()
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
          "window_title": $0.windowTitle, "text": $0.text,
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
        if v == revision, !(error is CancellationError) { onStatus("Completer: \(error.localizedDescription)") }
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
        render()
        if !chips.isEmpty {
          client.telemetry("chip_rendered", eventID: eventID, latencyMs: Date().timeIntervalSince(lastTyped) * 1000)
        }
      } catch {
        guard v == revision, !(error is CancellationError) else { return }
        chips = []
        render()
        onStatus("Router: \(error.localizedDescription)")
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
  }

  private var tabSafe: Bool { !(snapshot.map { Settings.tabUnsafeApps.contains($0.bundleID) } ?? false) }
  private var acceptKeyName: String { tabSafe ? "Tab" : "⌃Space" }

  private func syncKeyState() {
    tap.state = KeyTap.State(
      active: snapshot != nil && preview == nil && !busy, hasGhost: !ghost.isEmpty, chipCount: chips.count,
      tabSafe: tabSafe)
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
      acceptKey: acceptKeyName, anchor: anchor)
  }

  // MARK: - Keys

  /// Actions the key tap already decided to swallow, delivered on the main thread.
  private func perform(_ action: KeyTap.Action) {
    guard preview == nil, !busy, snapshot != nil else { return }
    switch action {
    case .dismiss: dismiss()
    case .accept: accept()
    case .ghostWord: insertGhost(wordOnly: true)
    case .cycle(let step):
      guard chips.count > 1 else { return }
      chosen = (chosen + step + chips.count) % chips.count
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
    busy = true
    clearSuggestions()
    render()
    previousApp = NSWorkspace.shared.frontmostApplication
    Task {
      do {
        let execution = try await client.prepare(
          eventID: eventID, skill: skill, buffer: buffer, fields: [:], previous: nil)
        await show(execution)
      } catch {
        previewPanel.showError(error.localizedDescription)
      }
      busy = false
      syncKeyState()
    }
  }

  // MARK: - Preview and execution

  private func show(_ execution: HelperClient.Execution) async {
    if execution.status == "preview" {
      preview = execution
      syncKeyState()
      previewPanel.showPreview(execution, label: client.label(for: execution.skill))
      return
    }
    preview = nil
    let effect = client.skill(execution.skill)?.side_effect_class ?? "preview-only"
    if effect == "preview-only", let result = execution.result {
      // Text results replace the typed intent, after focus returns to the field.
      previewPanel.orderOut(nil)
      await returnFocus()
      AccessibilityReader.replaceBeforeCaret(length: buffer.utf16.count, with: result, in: snapshot?.element)
      scheduleRefresh()
    } else {
      previewPanel.showDone(execution)
    }
  }

  private func submitPreview(_ fields: [String: String]) {
    guard let p = preview, !busy else { return }
    busy = true
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
        previewPanel.showError(error.localizedDescription)
        preview = nil
      }
      busy = false
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

  private func undo() {
    // The done panel is only shown for side-effecting results; its undo id lives in the last execution.
    guard let id = lastUndoID else { return }
    Task {
      do {
        try await client.undo(id: id)
        lastUndoID = nil
        previewPanel.showError("Undone.")
      } catch {
        previewPanel.showError(error.localizedDescription)
      }
    }
  }
  private var lastUndoID: String? {
    get { _lastUndo }
    set { _lastUndo = newValue }
  }
  private var _lastUndo: String?

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
