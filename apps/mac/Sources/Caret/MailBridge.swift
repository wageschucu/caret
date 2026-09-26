import Foundation

/// Searches the user's Mail messages with Caret's own header index of ~/Library/Mail (Full Disk Access).
/// Spotlight is not used: on some Macs it returns nothing for Mail. The index holds sender, subject,
/// date and path per message (no bodies), lives in Caret's support folder, is built in the background
/// and refreshed incrementally. Search results are bounded: three messages, 1,500 characters each.
final class MailBridge {
  struct BridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }
  struct Entry: Codable {
    let path: String
    let from: String
    let subject: String
    let date: Double  // seconds since 1970
  }

  private static let stopWords: Set<String> = [
    "the", "and", "for", "from", "about", "message", "mail", "email", "last", "latest", "recent", "their", "his",
    "her", "reply", "regarding", "with", "that", "this",
  ]
  private static let mailRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail").path
  private static let indexURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Caret")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("mail-index.json")
  }()

  static var hasAccess: Bool {
    FileManager.default.isReadableFile(atPath: mailRoot) && (try? FileManager.default.contentsOfDirectory(atPath: mailRoot)) != nil
  }

  private var entries: [String: Entry] = [:]  // by path
  private var loaded = false
  private var building = false
  private let queue = DispatchQueue(label: "caret.mailindex", qos: .utility)

  private var timer: Timer?

  /// Builds the index at launch and refreshes it every ten minutes; searches never wait for a walk.
  func refreshInBackground() {
    guard Self.hasAccess else { return }
    queue.async { [self] in self.refreshSync() }
    DispatchQueue.main.async { [self] in
      timer?.invalidate()
      timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
        guard let self, Self.hasAccess else { return }
        self.queue.async { self.refreshSync() }
      }
    }
  }

  private func refreshSync() {
    if building { return }
    building = true
    defer { building = false }
    if !loaded {
      if let data = try? Data(contentsOf: Self.indexURL), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
        entries = Dictionary(saved.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
      }
      loaded = true
    }
    let started = Date()
    var onDisk = Set<String>()
    guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: Self.mailRoot), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return }
    while let url = e.nextObject() as? URL {
      let name = url.lastPathComponent
      if name.hasSuffix(".emlx") {
        onDisk.insert(url.path)
      } else if name == "Attachments" {
        e.skipDescendants()
      }
    }
    let added = onDisk.subtracting(entries.keys)
    let removed = Set(entries.keys).subtracting(onDisk)
    for path in removed { entries.removeValue(forKey: path) }
    var parsed = 0
    for path in added {
      if let entry = Self.parseHeaders(path) {
        entries[path] = entry
        parsed += 1
      }
    }
    if !added.isEmpty || !removed.isEmpty {
      if let data = try? JSONEncoder().encode(Array(entries.values)) { try? data.write(to: Self.indexURL, options: .atomic) }
    }
    Diagnostics.log("mail index: \(entries.count) messages (\(parsed) added, \(removed.count) removed) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
  }

  func search(_ query: String, limit: Int = 3) async throws -> String {
    guard Self.hasAccess else {
      Diagnostics.log("mail.search: no access to ~/Library/Mail (Full Disk Access missing)")
      throw BridgeError(message: "Mail search needs Full Disk Access for Caret (System Settings → Privacy & Security → Full Disk Access).")
    }
    let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
      .filter { $0.count >= 3 && !Self.stopWords.contains($0) }
    guard !words.isEmpty else { throw BridgeError(message: "Nothing to search for.") }
    let snapshot: [Entry] = await withCheckedContinuation { continuation in
      queue.async { [self] in
        if !self.loaded { self.refreshSync() }  // first search before the launch build finished
        continuation.resume(returning: Array(self.entries.values))
      }
    }
    let ranked = snapshot.compactMap { e -> (Entry, Int)? in
      let hay = (e.from + " " + e.subject).lowercased()
      let score = words.filter { hay.contains($0) }.count
      return score > 0 ? (e, score) : nil
    }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.date > $1.0.date }
    if ranked.isEmpty {
      Diagnostics.log("mail.search: 0 hits for \(words) among \(snapshot.count) indexed")
      return "No messages match “\(query)”."
    }
    Diagnostics.log("mail.search: \(ranked.count) hits for \(words) among \(snapshot.count) indexed")
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE yyyy-MM-dd HH:mm"
    var out: [String] = []
    for (i, (e, _)) in ranked.prefix(limit).enumerated() {
      let body = Self.body(ofEmlx: e.path)
      out.append("--- message \(i + 1)\nfrom: \(e.from)\ndate: \(f.string(from: Date(timeIntervalSince1970: e.date)))\nsubject: \(e.subject)\n\(body)")
    }
    return out.joined(separator: "\n")
  }

  // MARK: - Header parsing (first bytes of each .emlx only)

  private static func parseHeaders(_ path: String) -> Entry? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    let data = handle.readData(ofLength: 12000)
    var text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
    if let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }  // byte-count line
    let headers = text.range(of: "\n\n").map { String(text[..<$0.lowerBound]) } ?? text
    let from = decodeRFC2047(headerValue("From", in: headers))
    let subject = decodeRFC2047(headerValue("Subject", in: headers))
    var date = parseDate(headerValue("Date", in: headers))
    if date == nil, let attrs = try? FileManager.default.attributesOfItem(atPath: path), let m = attrs[.modificationDate] as? Date { date = m }
    return Entry(path: path, from: from, subject: subject, date: (date ?? .distantPast).timeIntervalSince1970)
  }

  private static let dateFormats = ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz"]
  private static func parseDate(_ raw: String) -> Date? {
    var s = raw
    if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
    s = s.trimmingCharacters(in: .whitespaces)
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    for format in dateFormats {
      f.dateFormat = format
      if let d = f.date(from: s) { return d }
    }
    return nil
  }

  /// Decodes =?charset?B|Q?...?= encoded words (UTF-8 and Latin-1).
  static func decodeRFC2047(_ text: String) -> String {
    guard text.contains("=?") else { return text }
    var out = text
    let pattern = try! NSRegularExpression(pattern: "=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?=", options: [])
    let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
    for m in matches {
      guard let whole = Range(m.range, in: text), let cs = Range(m.range(at: 1), in: text), let enc = Range(m.range(at: 2), in: text), let payload = Range(m.range(at: 3), in: text) else { continue }
      let charset = text[cs].lowercased()
      var bytes: [UInt8] = []
      if text[enc].lowercased() == "b" {
        bytes = Array(Data(base64Encoded: String(text[payload])) ?? Data())
      } else {
        let q = text[payload].replacingOccurrences(of: "_", with: " ")
        var i = q.startIndex
        while i < q.endIndex {
          if q[i] == "=", let e = q.index(i, offsetBy: 3, limitedBy: q.endIndex), let v = UInt8(q[q.index(after: i)..<e], radix: 16) {
            bytes.append(v)
            i = e
          } else {
            bytes.append(contentsOf: Array(String(q[i]).utf8))
            i = q.index(after: i)
          }
        }
      }
      let decoded = charset.contains("8859") || charset.contains("latin") ? String(bytes.map { Character(UnicodeScalar($0)) }) : String(decoding: bytes, as: UTF8.self)
      out.replaceSubrange(whole, with: decoded)
    }
    return out
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
