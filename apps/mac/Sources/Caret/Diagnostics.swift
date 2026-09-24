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
