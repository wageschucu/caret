import AppKit
import ApplicationServices
import Foundation

/// Geometry-only log of focused fields, for debugging overlay placement per app.
/// Never contains field text. ~/Library/Logs/Caret/focus.log
enum Diagnostics {
  private static let url: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Caret")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("focus.log")
  }()

  private static let errors = url.deletingLastPathComponent().appendingPathComponent("caret.log")

  /// Errors and notable events, without field text. ~/Library/Logs/Caret/caret.log
  static func log(_ message: String) {
    append("\(ISO8601DateFormatter().string(from: Date())) \(message)\n", to: errors)
  }

  static func focus(_ s: FocusSnapshot) {
    func fmt(_ r: CGRect?) -> String {
      guard let r else { return "nil" }
      return String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
    }
    let line =
      "\(ISO8601DateFormatter().string(from: Date())) app=\(s.bundleID) role=\(s.role) subrole=\(s.subrole) "
      + "textLen=\(s.text.utf16.count) caret=\(s.caret) caretRect=\(fmt(s.caretRect)) frame=\(fmt(s.frame)) secure=\(s.secure)\n"
    append(line, to: url)
  }

  private static func append(_ line: String, to file: URL) {
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: file) {
      handle.seekToEndOfFile()
      handle.write(data)
      try? handle.close()
    } else {
      try? data.write(to: file)
    }
  }
}

extension Diagnostics {
  /// Dumps what the focused element exposes: attribute names, selection, character count, range reads,
  /// the first children, and WebKit text-marker support. Geometry and lengths only, no field text.
  /// ~/Library/Logs/Caret/diagnose.log
  static func dumpFocusedElement() {
    let system = AXUIElementCreateSystemWide()
    guard let raw = AccessibilityReader.attribute(system, kAXFocusedUIElementAttribute) else {
      log("diagnose: no focused element")
      return
    }
    let element = raw as! AXUIElement
    var lines: [String] = ["=== \(ISO8601DateFormatter().string(from: Date()))"]
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    lines.append("app=\(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?")")
    for name in [kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute] {
      lines.append("\(name)=\(AccessibilityReader.string(element, name) ?? "nil")")
    }
    var names: CFArray?
    AXUIElementCopyAttributeNames(element, &names)
    lines.append("attributes=\((names as? [String] ?? []).joined(separator: ","))")
    var pnames: CFArray?
    AXUIElementCopyParameterizedAttributeNames(element, &pnames)
    lines.append("parameterized=\((pnames as? [String] ?? []).joined(separator: ","))")
    let value = AccessibilityReader.string(element, kAXValueAttribute)
    lines.append("valueLen=\(value?.utf16.count ?? -1)")
    if let n = AccessibilityReader.attribute(element, kAXNumberOfCharactersAttribute) as? Int {
      lines.append("numberOfCharacters=\(n)")
    } else {
      lines.append("numberOfCharacters=nil")
    }
    if let sel = AccessibilityReader.range(element, kAXSelectedTextRangeAttribute) {
      lines.append("selectedTextRange=(\(sel.location),\(sel.length))")
      let probe = AccessibilityReader.stringForRange(element, location: max(0, sel.location - 50), length: min(50, sel.location))
      lines.append("stringForRange(before caret)Len=\(probe?.utf16.count ?? -1)")
    } else {
      lines.append("selectedTextRange=nil")
    }
    let probe0 = AccessibilityReader.stringForRange(element, location: 0, length: 20)
    lines.append("stringForRange(0,20)Len=\(probe0?.utf16.count ?? -1)")
    if let children = AccessibilityReader.attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
      let roles = children.prefix(12).map {
        "\(AccessibilityReader.string($0, kAXRoleAttribute) ?? "?")(\(AccessibilityReader.string($0, kAXValueAttribute)?.utf16.count ?? -1))"
      }
      lines.append("children[\(children.count)]=\(roles.joined(separator: ","))")
    }
    // WebKit text markers: the mechanism VoiceOver uses for web content.
    var marker: CFTypeRef?
    let hasMarkers = AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &marker) == .success
    lines.append("AXSelectedTextMarkerRange=\(hasMarkers ? "yes" : "no")")
    if hasMarkers, let markerRange = marker {
      var text: CFTypeRef?
      let ok = AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString, markerRange, &text) == .success
      lines.append("AXStringForTextMarkerRange(selection)=\(ok ? "ok len \((text as? String)?.utf16.count ?? -1)" : "no")")
      var startMarker: CFTypeRef?
      let hasStart = AXUIElementCopyAttributeValue(element, "AXStartTextMarker" as CFString, &startMarker) == .success
      lines.append("AXStartTextMarker=\(hasStart ? "yes" : "no")")
    }
    let file = url.deletingLastPathComponent().appendingPathComponent("diagnose.log")
    append(lines.joined(separator: "\n") + "\n", to: file)
    log("diagnose: wrote \(lines.count) lines")
  }
}
