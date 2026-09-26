import Foundation

/// Searches the user's Mail messages through Spotlight's index (needs Full Disk Access) and reads the
/// matched .emlx files for their text. Bounded: at most three messages, 1,500 characters each.
/// Any word of the query may match the sender or the subject, so a one-letter slip still finds the mail.
final class MailBridge {
  struct BridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }
  private static let stopWords: Set<String> = [
    "the", "and", "for", "from", "about", "message", "mail", "email", "last", "latest", "recent", "their", "his",
    "her", "reply", "regarding", "with", "that", "this",
  ]
  private static let mailRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail").path

  static var hasAccess: Bool { FileManager.default.isReadableFile(atPath: mailRoot) && (try? FileManager.default.contentsOfDirectory(atPath: mailRoot)) != nil }

  func search(_ query: String, limit: Int = 3) async throws -> String {
    guard Self.hasAccess else {
      throw BridgeError(message: "Mail search needs Full Disk Access for Caret (System Settings → Privacy & Security → Full Disk Access).")
    }
    let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
      .filter { $0.count >= 3 && !Self.stopWords.contains($0) }
    guard !words.isEmpty else { throw BridgeError(message: "Nothing to search for.") }
    let clauses = words.map { w in
      let q = w.replacingOccurrences(of: "\"", with: "")
      return "(kMDItemAuthors == \"*\(q)*\"c || kMDItemAuthorEmailAddresses == \"*\(q)*\"c || kMDItemSubject == \"*\(q)*\"c)"
    }
    let predicate = "kMDItemContentType == \"com.apple.mail.emlx\" && (\(clauses.joined(separator: " || ")))"
    let paths = try Self.run("/usr/bin/mdfind", ["-onlyin", Self.mailRoot, predicate])
      .split(separator: "\n").map(String.init).filter { !$0.isEmpty }.prefix(60)
    if paths.isEmpty { return "No messages match “\(query)”." }
    // Rank: more query words matched first, then newest.
    var candidates: [(path: String, date: Date, from: String, subject: String, score: Int)] = []
    for path in paths {
      let meta = Self.metadata(path)
      let hay = (meta.from + " " + meta.subject).lowercased()
      let score = words.filter { hay.contains($0) }.count
      candidates.append((path, meta.date, meta.from, meta.subject, score))
    }
    candidates.sort { $0.score != $1.score ? $0.score > $1.score : $0.date > $1.date }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE yyyy-MM-dd HH:mm"
    var out: [String] = []
    for (i, c) in candidates.prefix(limit).enumerated() {
      let body = Self.body(ofEmlx: c.path)
      out.append("--- message \(i + 1)\nfrom: \(c.from)\ndate: \(f.string(from: c.date))\nsubject: \(c.subject)\n\(body)")
    }
    return out.joined(separator: "\n")
  }

  // MARK: - Spotlight helpers

  private static func run(_ tool: String, _ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }

  private static func metadata(_ path: String) -> (from: String, subject: String, date: Date) {
    let raw = (try? run("/usr/bin/mdls", ["-name", "kMDItemAuthors", "-name", "kMDItemAuthorEmailAddresses", "-name", "kMDItemSubject", "-name", "kMDItemContentCreationDate", "-raw", "-nullMarker", "", path])) ?? ""
    // -raw prints values separated by NUL.
    let parts = raw.split(separator: "\0", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    let clean = { (s: String) -> String in s.replacingOccurrences(of: "(\n", with: "").replacingOccurrences(of: "\n)", with: "").replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
    let authors = clean(parts.count > 0 ? parts[0] : "")
    let addresses = clean(parts.count > 1 ? parts[1] : "")
    let subject = clean(parts.count > 2 ? parts[2] : "")
    let dateText = parts.count > 3 ? parts[3] : ""
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    let date = df.date(from: dateText) ?? Date.distantPast
    let from = addresses.isEmpty ? authors : (authors.isEmpty ? addresses : "\(authors) <\(addresses)>")
    return (from, subject, date)
  }

  // MARK: - .emlx body extraction (text/plain preferred, HTML stripped otherwise)

  static func body(ofEmlx path: String, limit: Int = 1500) -> String {
    guard let data = FileManager.default.contents(atPath: path) else { return "(message text unavailable)" }
    var text = String(decoding: data, as: UTF8.self)
    // First line is the byte count; the message follows; a plist trails it.
    if let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
    if let plist = text.range(of: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist") { text = String(text[..<plist.lowerBound]) }
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    guard let split = normalized.range(of: "\n\n") else { return String(normalized.prefix(limit)) }
    let headers = String(normalized[..<split.lowerBound])
    var payload = String(normalized[split.upperBound...])
    var encoding = headerValue("Content-Transfer-Encoding", in: headers)
    var contentType = headerValue("Content-Type", in: headers)
    if contentType.lowercased().hasPrefix("multipart/"), let outer = Self.boundary(in: contentType) {
      let parts = payload.components(separatedBy: "--" + outer).dropFirst()
      var chosen: (type: String, body: String, encoding: String)? = nil
      for part in parts {
        guard let s = part.range(of: "\n\n") else { continue }
        let h = String(part[..<s.lowerBound])
        let b = String(part[s.upperBound...])
        let t = headerValue("Content-Type", in: h).lowercased()
        let e = headerValue("Content-Transfer-Encoding", in: h)
        if t.hasPrefix("text/plain") {
          chosen = (t, b, e)
          break
        }
        if t.hasPrefix("text/html"), chosen == nil { chosen = (t, b, e) }
        if t.hasPrefix("multipart/"), let inner = Self.boundary(in: t) {
          // One level of nesting is common (alternative inside mixed).
          for sub in b.components(separatedBy: "--" + inner).dropFirst() {
            guard let ss = sub.range(of: "\n\n") else { continue }
            let sh = String(sub[..<ss.lowerBound])
            let st = headerValue("Content-Type", in: sh).lowercased()
            if st.hasPrefix("text/plain") {
              chosen = (st, String(sub[ss.upperBound...]), headerValue("Content-Transfer-Encoding", in: sh))
              break
            }
            if st.hasPrefix("text/html"), chosen == nil {
              chosen = (st, String(sub[ss.upperBound...]), headerValue("Content-Transfer-Encoding", in: sh))
            }
          }
          if chosen?.type.hasPrefix("text/plain") == true { break }
        }
      }
      if let chosen {
        payload = chosen.body
        encoding = chosen.encoding
        contentType = chosen.type
      }
    }
    var decoded = decode(payload, encoding: encoding)
    if contentType.lowercased().hasPrefix("text/html") { decoded = stripHTML(decoded) }
    decoded = decoded.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    return String(decoded.prefix(limit))
  }

  private static func headerValue(_ name: String, in headers: String) -> String {
    let lines = headers.components(separatedBy: "\n")
    var value: String? = nil
    for line in lines {
      if value != nil {
        if line.hasPrefix(" ") || line.hasPrefix("\t") { value! += " " + line.trimmingCharacters(in: .whitespaces) } else { break }
      } else if line.lowercased().hasPrefix(name.lowercased() + ":") {
        value = String(line.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
      }
    }
    return value ?? ""
  }

  private static func boundary(in contentType: String) -> String? {
    guard let r = contentType.range(of: "boundary=", options: .caseInsensitive) else { return nil }
    var b = String(contentType[r.upperBound...])
    if let semi = b.firstIndex(of: ";") { b = String(b[..<semi]) }
    return b.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).isEmpty ? nil : b.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
  }

  private static func decode(_ text: String, encoding: String) -> String {
    switch encoding.lowercased() {
    case "base64":
      let compact = text.filter { !$0.isWhitespace }
      if let data = Data(base64Encoded: compact), let s = String(data: data, encoding: .utf8) { return s }
      return text
    case "quoted-printable":
      var s = text.replacingOccurrences(of: "=\n", with: "")
      var bytes: [UInt8] = []
      var i = s.startIndex
      while i < s.endIndex {
        if s[i] == "=", let e = s.index(i, offsetBy: 3, limitedBy: s.endIndex), let v = UInt8(s[s.index(after: i)..<e], radix: 16) {
          bytes.append(v)
          i = e
        } else {
          bytes.append(contentsOf: Array(String(s[i]).utf8))
          i = s.index(after: i)
        }
      }
      s = String(decoding: bytes, as: UTF8.self)
      return s
    default:
      return text
    }
  }

  private static func stripHTML(_ html: String) -> String {
    var s = html.replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: "", options: [.regularExpression, .caseInsensitive])
    s = s.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: "", options: [.regularExpression, .caseInsensitive])
    s = s.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</tr>|</h[1-6]>", with: "\n", options: [.regularExpression, .caseInsensitive])
    s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
      s = s.replacingOccurrences(of: entity, with: char)
    }
    return s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
  }
}
