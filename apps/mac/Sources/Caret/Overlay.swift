import AppKit

/// Floating, non-activating panel drawn at the caret: ghost text above, chips below.
final class OverlayPanel: NSPanel {
  private let ghostLabel = NSTextField(labelWithString: "")
  private let hintLabel = NSTextField(labelWithString: "")
  private let chipRow = NSStackView()
  private let workingPill = WorkingPill()
  private let variantRow = NSStackView()
  private let styleRow = NSStackView()
  private let stack = NSStackView()

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    level = .statusBar
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = true
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    isReleasedWhenClosed = false

    ghostLabel.font = NSFont.systemFont(ofSize: 14)
    ghostLabel.textColor = NSColor.secondaryLabelColor
    ghostLabel.lineBreakMode = .byTruncatingTail
    ghostLabel.maximumNumberOfLines = 2
    ghostLabel.preferredMaxLayoutWidth = 480
    ghostLabel.wantsLayer = true
    ghostLabel.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
    ghostLabel.layer?.cornerRadius = 4

    chipRow.orientation = .horizontal
    chipRow.spacing = 6
    variantRow.orientation = .horizontal
    variantRow.spacing = 4
    styleRow.orientation = .horizontal
    styleRow.spacing = 4

    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    hintLabel.font = NSFont.systemFont(ofSize: 11)
    hintLabel.textColor = NSColor.tertiaryLabelColor
    hintLabel.wantsLayer = true
    hintLabel.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
    hintLabel.layer?.cornerRadius = 4
    stack.addArrangedSubview(ghostLabel)
    stack.addArrangedSubview(workingPill)
    workingPill.isHidden = true
    stack.addArrangedSubview(chipRow)
    stack.addArrangedSubview(variantRow)
    stack.addArrangedSubview(styleRow)
    stack.addArrangedSubview(hintLabel)
    contentView = stack
  }

  /// Renders the overlay anchored to `anchor` (AppKit screen coordinates). Hides when there is nothing to show.
  func show(
    ghost: String, chips: [(label: String, selected: Bool)], acceptKey: String, anchor: CGRect,
    working: String? = nil, hint: String? = nil, variants: [(label: String, selected: Bool)] = [],
    styles: [(label: String, selected: Bool)] = []
  ) {
    guard !ghost.isEmpty || !chips.isEmpty || working != nil || hint != nil else {
      orderOut(nil)
      return
    }
    hintLabel.stringValue = hint ?? ""
    hintLabel.isHidden = hint == nil || working != nil
    if let working {
      // A busy pill replaces ghost text and chips while the executor runs.
      ghostLabel.isHidden = true
      workingPill.show(working)
      chipRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
      chipRow.isHidden = true
      variantRow.isHidden = true
      styleRow.isHidden = true
      place(at: anchor)
      return
    }
    workingPill.hide()
    styleRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for v in styles { styleRow.addArrangedSubview(VariantPill(label: v.label, selected: v.selected, arrow: false)) }
    if !styles.isEmpty {
      let arrows = NSTextField(labelWithString: "⌥← ⌥→")
      arrows.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
      arrows.textColor = .tertiaryLabelColor
      styleRow.addArrangedSubview(arrows)
    }
    styleRow.isHidden = styles.isEmpty
    variantRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for v in variants { variantRow.addArrangedSubview(VariantPill(label: v.label, selected: v.selected)) }
    if !variants.isEmpty {
      let arrows = NSTextField(labelWithString: "← →")
      arrows.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
      arrows.textColor = .tertiaryLabelColor
      variantRow.addArrangedSubview(arrows)
    }
    variantRow.isHidden = variants.isEmpty
    ghostLabel.stringValue = ghost
    ghostLabel.isHidden = ghost.isEmpty
    ghostLabel.alphaValue = chips.isEmpty ? 1 : 0.6
    chipRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for chip in chips { chipRow.addArrangedSubview(ChipView(label: chip.label, key: acceptKey, selected: chip.selected)) }
    chipRow.isHidden = chips.isEmpty
    place(at: anchor)
  }

  private func place(at anchor: CGRect) {
    stack.layoutSubtreeIfNeeded()
    let size = stack.fittingSize
    var origin = CGPoint(x: anchor.minX, y: anchor.minY - size.height - 6)
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) })
      ?? NSScreen.main
    {
      let visible = screen.visibleFrame
      if origin.y < visible.minY { origin.y = anchor.maxY + 6 }
      origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
    }
    setFrame(NSRect(origin: origin, size: size), display: true)
    orderFrontRegardless()
  }

  func hide() { orderOut(nil) }
}

/// One action chip: label plus the key that accepts it. No probabilities, ever.
final class ChipView: NSView {
  init(label: String, key: String, selected: Bool) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
    layer?.backgroundColor = (selected ? NSColor.controlAccentColor : NSColor.windowBackgroundColor).cgColor
    layer?.borderColor = NSColor.controlAccentColor.cgColor
    let title = NSTextField(labelWithString: label + " ↗")
    title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
    title.textColor = selected ? .white : .labelColor
    let hint = NSTextField(labelWithString: key)
    hint.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    hint.textColor = selected ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
    let row = NSStackView(views: [title, hint])
    row.orientation = .horizontal
    row.spacing = 8
    row.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }
  required init?(coder: NSCoder) { nil }
}

/// A destination option under the highlighted chip, e.g. a target currency.
final class VariantPill: NSView {
  init(label: String, selected: Bool, arrow: Bool = true) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.borderWidth = 1
    layer?.borderColor = (selected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    layer?.backgroundColor =
      (selected ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.windowBackgroundColor).cgColor
    let title = NSTextField(labelWithString: (arrow ? "→ " : "") + label)
    title.font = NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular)
    title.textColor = selected ? .labelColor : .secondaryLabelColor
    title.translatesAutoresizingMaskIntoConstraints = false
    addSubview(title)
    NSLayoutConstraint.activate([
      title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
      title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
      title.topAnchor.constraint(equalTo: topAnchor, constant: 3),
      title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
    ])
  }
  required init?(coder: NSCoder) { nil }
}

/// "Working…" indicator shown at the caret while a skill runs: spinner plus the skill's name.
final class WorkingPill: NSView {
  private let spinner = NSProgressIndicator()
  private let title = NSTextField(labelWithString: "")

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 9
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
    layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
    shadow = NSShadow()
    shadow?.shadowBlurRadius = 6
    shadow?.shadowOffset = NSSize(width: 0, height: -1)
    shadow?.shadowColor = NSColor.black.withAlphaComponent(0.18)
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isIndeterminate = true
    spinner.isDisplayedWhenStopped = false
    title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
    title.textColor = .labelColor
    let row = NSStackView(views: [spinner, title])
    row.orientation = .horizontal
    row.spacing = 7
    row.alignment = .centerY
    row.edgeInsets = NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 11)
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }
  required init?(coder: NSCoder) { nil }

  private var started: Date?
  private var ticker: Timer?
  private var base = ""

  func show(_ text: String) {
    if isHidden || base != text {
      started = Date()
      base = text
    }
    isHidden = false
    spinner.startAnimation(nil)
    ticker?.invalidate()
    ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    tick()
  }

  private func tick() {
    let seconds = Int(Date().timeIntervalSince(started ?? Date()))
    title.stringValue = seconds >= 3 ? "\(base)  \(seconds)s" : base
  }

  func hide() {
    ticker?.invalidate()
    ticker = nil
    started = nil
    spinner.stopAnimation(nil)
    isHidden = true
  }
}
