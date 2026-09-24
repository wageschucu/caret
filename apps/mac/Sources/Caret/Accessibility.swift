import AppKit
import ApplicationServices
import Carbon

/// What the host knows about the focused text field right now.
struct FocusSnapshot {
  let element: AXUIElement
  let pid: pid_t
  let role: String
  let subrole: String
  let bundleID: String
  let appName: String
  let windowTitle: String
  /// Full field value, capped.
  let text: String
  /// Caret offset in UTF-16 units, and selection length.
  let caret: Int
  let selectionLength: Int
  let selectedText: String
  let secure: Bool
  /// Caret rectangle in AppKit screen coordinates (origin bottom-left), when the app reports one.
  let caretRect: CGRect?
  /// Field frame in AppKit screen coordinates, used as a fallback anchor.
  let frame: CGRect?

  /// Windows captured before this read, newest last. In memory only.
  let recent: [RecentWindow]

  /// Text before the caret, limited to the current paragraph (or line) and a sane length.
  func buffer(lineOnly: Bool) -> String {
    let utf16 = Array(text.utf16)
    let end = min(max(caret, 0), utf16.count)
    var slice = String(utf16CodeUnits: Array(utf16[0..<end]), count: end)
    if let range = slice.range(of: lineOnly ? "\n" : "\n\n", options: .backwards) {
      slice = String(slice[range.upperBound...])
    }
    // Terminal lines start with a shell prompt; drop it so only the typed command remains.
    if lineOnly, let prompt = slice.range(of: #"^[^\n]{0,120}?[$%#>] "#, options: .regularExpression) {
      slice = String(slice[prompt.upperBound...])
    }
    if slice.count > 2000 { slice = String(slice.suffix(2000)) }
    return slice
  }

  var caretAtEnd: Bool { caret >= text.utf16.count && selectionLength == 0 }
}

/// A captured window, kept in memory only, for the `screens` context array.
struct RecentWindow {
  let timestamp: Date
  let bundleID: String
  let windowTitle: String
  let text: String
}

/// Reads the focused field and recent windows through the Accessibility API.
/// Nothing here is written to disk.
final class AccessibilityReader {
  private let systemWide = AXUIElementCreateSystemWide()
  private(set) var recent: [RecentWindow] = []
  private var lastWindowKey = ""
  private var enhancedApps: Set<pid_t> = []

  static func isTrusted(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
  }

  // MARK: - Attribute helpers

  static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return error == .success ? value : nil
  }

  static func string(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
  }

  static func range(_ element: AXUIElement, _ name: String) -> CFRange? {
    guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
  }

  static func rect(_ value: AnyObject?) -> CGRect? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var rect = CGRect.zero
    return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
  }

  static func boundsForRange(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
    var range = CFRange(location: location, length: length)
    guard let param = AXValueCreate(.cfRange, &range) else { return nil }
    var value: CFTypeRef?
    let error = AXUIElementCopyParameterizedAttributeValue(
      element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &value)
    guard error == .success, let rect = rect(value) else { return nil }
    // Chromium/Electron and Terminal answer with a zero-size rect on the screen edge; a real caret has height.
    return rect.height < 1 ? nil : rect
  }

  /// Quartz (top-left origin) → AppKit (bottom-left origin) screen coordinates.
  static func appKitRect(_ quartz: CGRect) -> CGRect {
    let height = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: quartz.minX, y: height - quartz.maxY, width: quartz.width, height: quartz.height)
  }

  static func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
      AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
    else { return nil }
    return CGRect(origin: point, size: dimensions)
  }

  // MARK: - Focused field

  private static let textRoles: Set<String> = [
    kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField", "AXWebArea",
  ]

  func focused() -> FocusSnapshot? {
    guard let raw = Self.attribute(systemWide, kAXFocusedUIElementAttribute) else { return nil }
    var element = raw as! AXUIElement
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    let running = NSRunningApplication(processIdentifier: pid)
    let bundleID = running?.bundleIdentifier ?? "pid.\(pid)"
    let appName = running?.localizedName ?? bundleID

    let appElement = AXUIElementCreateApplication(pid)
    enableFullTree(appElement, pid: pid)
    var role = Self.string(element, kAXRoleAttribute) ?? ""
    if role == "AXWebArea",
      let inner = Self.attribute(appElement, kAXFocusedUIElementAttribute).map({ $0 as! AXUIElement }),
      !CFEqual(inner, element), let innerRole = Self.string(inner, kAXRoleAttribute), innerRole != "AXWebArea"
    {
      // Chromium first reports the page itself; once the full tree is on, the app knows the real field.
      element = inner
      role = innerRole
    }
    let subrole = Self.string(element, kAXSubroleAttribute) ?? ""
    let secure = subrole == kAXSecureTextFieldSubrole || IsSecureEventInputEnabled()
    let selection = Self.range(element, kAXSelectedTextRangeAttribute)
    // Anything with a selected text range behaves like a text field for our purposes.
    guard Self.textRoles.contains(role) || selection != nil else { return nil }

    let window = Self.attribute(appElement, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
    let windowTitle = window.flatMap { Self.string($0, kAXTitleAttribute) } ?? ""
    captureWindowIfChanged(window, bundleID: bundleID, title: windowTitle)

    if secure {
      return FocusSnapshot(
        element: element, pid: pid, role: role, subrole: subrole, bundleID: bundleID, appName: appName,
        windowTitle: windowTitle, text: "", caret: 0, selectionLength: 0, selectedText: "", secure: true,
        caretRect: nil, frame: nil, recent: recent)
    }

    var text = Self.string(element, kAXValueAttribute) ?? ""
    if text.utf16.count > 20000 { text = String(text.suffix(20000)) }
    let caret = selection?.location ?? text.utf16.count
    let selectionLength = selection?.length ?? 0
    let selectedText = selectionLength > 0 ? (Self.string(element, kAXSelectedTextAttribute) ?? "") : ""

    var caretRect = Self.boundsForRange(element, location: caret, length: 0)
    if caretRect == nil, caret > 0 {
      caretRect = Self.boundsForRange(element, location: caret - 1, length: 1).map {
        CGRect(x: $0.maxX, y: $0.minY, width: 1, height: $0.height)
      }
    }
    return FocusSnapshot(
      element: element, pid: pid, role: role, subrole: subrole, bundleID: bundleID, appName: appName,
      windowTitle: windowTitle, text: text, caret: caret, selectionLength: selectionLength, selectedText: selectedText, secure: false,
      caretRect: caretRect.map(Self.appKitRect), frame: Self.frame(element).map(Self.appKitRect), recent: recent)
  }

  /// Chromium and Electron apps expose a skeleton accessibility tree until an assistive client asks
  /// for the full one. Without this the focused element is the whole web area and caret bounds are missing.
  private func enableFullTree(_ appElement: AXUIElement, pid: pid_t) {
    guard !enhancedApps.contains(pid) else { return }
    enhancedApps.insert(pid)
    AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
  }

  // MARK: - Recent windows

  private func captureWindowIfChanged(_ window: AXUIElement?, bundleID: String, title: String) {
    guard Settings.screenContext, let window else { return }
    let key = bundleID + "\u{1}" + title
    guard key != lastWindowKey else { return }
    lastWindowKey = key
    var parts: [String] = []
    var budget = 2000
    Self.collectText(window, depth: 0, parts: &parts, budget: &budget)
    let text = parts.joined(separator: "\n")
    guard !text.isEmpty else { return }
    recent.append(RecentWindow(timestamp: Date(), bundleID: bundleID, windowTitle: title, text: text))
    if recent.count > 4 { recent.removeFirst(recent.count - 4) }
  }

  private static func collectText(_ element: AXUIElement, depth: Int, parts: inout [String], budget: inout Int) {
    guard depth < 12, budget > 0 else { return }
    let role = string(element, kAXRoleAttribute) ?? ""
    if role == kAXStaticTextRole || role == kAXTextAreaRole || role == kAXTextFieldRole {
      if string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole { return }
      if let value = string(element, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty
      {
        let clipped = String(value.prefix(budget))
        parts.append(clipped)
        budget -= clipped.count
        return
      }
    }
    guard let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
    for child in children.prefix(60) {
      collectText(child, depth: depth + 1, parts: &parts, budget: &budget)
      if budget <= 0 { return }
    }
  }

  // MARK: - Insertion

  /// Inserts text at the caret. Accessibility first (atomic, layout-independent), then synthetic keystrokes.
  /// Replaces the `length` UTF-16 units before the caret (the intent the user typed) with `text`.
  /// Falls back to plain insertion when the app does not let us move the selection.
  static func replaceBeforeCaret(length: Int, with text: String, in element: AXUIElement?) {
    if let element, length > 0, let selection = range(element, kAXSelectedTextRangeAttribute),
      selection.location >= length
    {
      var target = CFRange(location: selection.location - length, length: length)
      if let value = AXValueCreate(.cfRange, &target),
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success,
        let check = range(element, kAXSelectedTextRangeAttribute), check.location == target.location,
        check.length == length
      {
        insert(text, into: element)
        return
      }
    }
    insert(text, into: element)
  }

  static func insert(_ text: String, into element: AXUIElement?) {
    if let element {
      var settable = DarwinBoolean(false)
      if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
        settable.boolValue,
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
      {
        return
      }
    }
    typeUnicode(text)
  }

  static func typeUnicode(_ text: String) {
    let source = CGEventSource(stateID: .combinedSessionState)
    let units = Array(text.utf16)
    var index = 0
    while index < units.count {
      var chunk = Array(units[index..<min(index + 20, units.count)])
      index += chunk.count
      guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
      else { return }
      down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
      up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)
    }
  }
}
