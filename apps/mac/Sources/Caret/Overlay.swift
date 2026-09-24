import AppKit

/// Floating, non-activating panel drawn at the caret: ghost text above, chips below.
final class OverlayPanel: NSPanel {
  private let ghostLabel = NSTextField(labelWithString: "")
  private let chipRow = NSStackView()
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

    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    stack.addArrangedSubview(ghostLabel)
    stack.addArrangedSubview(chipRow)
    contentView = stack
  }

  /// Renders the overlay anchored to `anchor` (AppKit screen coordinates). Hides when there is nothing to show.
  func show(
    ghost: String, chips: [(label: String, selected: Bool)], acceptKey: String, anchor: CGRect, working: String? = nil
  ) {
    guard !ghost.isEmpty || !chips.isEmpty || working != nil else {
      orderOut(nil)
      return
    }
    if let working {
      // A busy pill replaces ghost text and chips while the executor runs.
      ghostLabel.stringValue = "⋯ " + working
      ghostLabel.isHidden = false
      ghostLabel.alphaValue = 1
      chipRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
      chipRow.isHidden = true
      place(at: anchor)
      return
    }
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
