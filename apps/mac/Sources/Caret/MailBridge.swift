import Foundation

/// Searches recent inbox messages in Apple Mail through AppleScript (one-time Automation prompt).
/// Bounded to the newest messages so a large inbox answers in a second or two.
final class MailBridge {
  struct BridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  /// "from / date / subject / text" blocks for up to `limit` messages matching `query` in sender or subject.
  func search(_ query: String, limit: Int = 3, scan: Int = 300) async throws -> String {
    let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let script = """
      tell application "Mail"
        set q to "\(escaped)"
        set out to ""
        set n to 0
        set msgs to messages of inbox
        set total to count of msgs
        if total > \(scan) then set total to \(scan)
        repeat with i from 1 to total
          set m to item i of msgs
          set s to subject of m
          set f to sender of m
          if (s contains q) or (f contains q) then
            set body to content of m
            if (length of body) > 1500 then set body to text 1 thru 1500 of body
            set out to out & "--- message " & (n + 1) & linefeed & "from: " & f & linefeed & "date: " & ((date received of m) as string) & linefeed & "subject: " & s & linefeed & body & linefeed
            set n to n + 1
            if n ≥ \(limit) then exit repeat
          end if
        end repeat
        return out
      end tell
      """
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
          let message = (error[NSAppleScript.errorMessage] as? String) ?? "Mail could not be searched"
          continuation.resume(throwing: BridgeError(message: message))
          return
        }
        let text = result?.stringValue ?? ""
        continuation.resume(returning: text.isEmpty ? "No recent inbox messages match “\(query)”." : text)
      }
    }
  }
}
