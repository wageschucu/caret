import AppKit

/// Debug view: the one place probabilities are shown (spec §7.2). Recent routing decisions with
/// ready/skill probabilities against the current thresholds, plus registry history with rollback.
@MainActor
final class DebugWindow: NSPanel {
  var fetch: () async throws -> [String: Any] = { [:] }
  var rollback: (String) async throws -> String = { _ in "" }
  var refreshed: () -> Void = {}
  private let text = NSTextView()
  private let versions = NSPopUpButton()
  private let rollbackButton = NSButton(title: "Roll back to selected version", target: nil, action: nil)
  private let status = NSTextField(wrappingLabelWithString: "")
  private var timer: Timer?
  private var hashes: [String] = []
  private var armed = false

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
      styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
    title = "Caret — debug"
    level = .floating
    isReleasedWhenClosed = false
    collectionBehavior = [.moveToActiveSpace]
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
    text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    text.isEditable = false
    let scroll = NSScrollView()
    scroll.documentView = text
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.borderType = .bezelBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.widthAnchor.constraint(equalToConstant: 788).isActive = true
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
    text.isHorizontallyResizable = true
    text.textContainer?.widthTracksTextView = false
    text.textContainer?.containerSize = NSSize(width: 4000, height: CGFloat.greatestFiniteMagnitude)
    stack.addArrangedSubview(scroll)
    rollbackButton.target = self
    rollbackButton.action = #selector(rollbackPressed)
    rollbackButton.bezelStyle = .rounded
    let row = NSStackView(views: [NSTextField(labelWithString: "Registry version:"), versions, rollbackButton])
    row.orientation = .horizontal
    stack.addArrangedSubview(row)
    status.font = NSFont.systemFont(ofSize: 11)
    status.textColor = .secondaryLabelColor
    status.preferredMaxLayoutWidth = 780
    stack.addArrangedSubview(status)
    contentView = stack
  }

  override var canBecomeKey: Bool { true }

  func present() {
    center()
    orderFrontRegardless()
    makeKey()
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.refresh() }
    }
    Task { await refresh() }
  }

  override func orderOut(_ sender: Any?) {
    timer?.invalidate()
    timer = nil
    super.orderOut(sender)
  }

  override func close() {
    timer?.invalidate()
    timer = nil
    super.close()
  }

  private func refresh() async {
    guard isVisible else { return }
    do {
      let info = try await fetch()
      render(info)
    } catch {
      status.stringValue = "Could not read debug data: \(error.localizedDescription)"
    }
  }

  private func render(_ info: [String: Any]) {
    var lines: [String] = []
    if let t = info["thresholds"] as? [String: Any] {
      let keys = ["version", "ready", "entry", "single", "margin", "hold", "largeSet", "ratio", "largeSetMargin"]
      lines.append("thresholds  " + keys.compactMap { k in t[k].map { "\(k)=\($0)" } }.joined(separator: "  "))
    }
    lines.append("registry    \(String((info["registry_hash"] as? String ?? "").prefix(12)))…")
    lines.append("")
    lines.append(String(format: "%-8@ %-22@ %-38@ %6@  %-42@ %-22@ %6@", "time", "app", "typed", "ready", "top probabilities", "shown", "ms"))
    for e in info["recent"] as? [[String: Any]] ?? [] {
      let time = String((e["ts"] as? String ?? "").dropFirst(11).prefix(8))
      let app = String(String(((e["app"] as? String) ?? "").split(separator: ".").last ?? "").prefix(22))
      let typed = String((e["buffer"] as? String ?? "").replacingOccurrences(of: "\n", with: "⏎").prefix(38))
      let ready = String(format: "%.2f", (e["ready_p"] as? Double) ?? 0)
      let probs = (e["distribution"] as? [[Any]] ?? []).prefix(3).map { pair -> String in
        let name = (pair.first as? String ?? "?").replacingOccurrences(of: "none_of_the_above", with: "∅")
        return "\(String(name.prefix(14))) \(String(format: "%.2f", pair.last as? Double ?? 0))"
      }.joined(separator: " ")
      let shown = ((e["shown"] as? [String]) ?? []).joined(separator: ",")
      let ms = "\(e["latency_ms"] as? Int ?? 0)"
      lines.append(String(format: "%-8@ %-22@ %-38@ %6@  %-42@ %-22@ %6@", time, app, typed, ready, String(probs.prefix(42)), String(shown.prefix(22)), ms))
    }
    text.string = lines.joined(separator: "\n")
    let history = info["history"] as? [[String: Any]] ?? []
    let newHashes = history.compactMap { $0["registry_hash"] as? String }
    if newHashes != hashes {
      hashes = newHashes
      versions.removeAllItems()
      for h in history {
        let ts = String((h["ts"] as? String ?? "").prefix(16)).replacingOccurrences(of: "T", with: " ")
        let action = h["action"] as? String ?? ""
        let slug = (h["slug"] as? String).map { " \($0)" } ?? ""
        versions.addItem(withTitle: "\(ts)  \(action)\(slug)  \((h["registry_hash"] as? String ?? "").prefix(8))  (\(h["count"] as? Int ?? 0) skills)")
      }
    }
    if !armed { status.stringValue = "Probabilities are shown here only. Rolling back rewrites skills/ from the chosen snapshot; skills added since are moved to .skillrouter/trash, not deleted." }
  }

  @objc private func rollbackPressed() {
    let index = versions.indexOfSelectedItem
    guard index >= 0, index < hashes.count else { return }
    if !armed {
      armed = true
      rollbackButton.title = "Click again to confirm rollback"
      status.stringValue = "This rewrites the skill files. Click again to confirm, or pick another version to cancel."
      return
    }
    armed = false
    rollbackButton.title = "Roll back to selected version"
    let hash = hashes[index]
    Task {
      do {
        status.stringValue = try await rollback(hash)
        refreshed()
        await refresh()
      } catch {
        status.stringValue = "Rollback failed: \(error.localizedDescription)"
      }
    }
  }
}
