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
      Diagnostics.log("mail.search: no access to ~/Library/Mail (Full Disk Access missing)")
      throw BridgeError(message: "Mail search needs Full Disk Access for Caret (System Settings → Privacy & Security → Full Disk Access).")
    }
    let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
      .filter { $0.count >= 3 && !Self.stopWords.contains($0) }
    guard !words.isEmpty else { throw BridgeError(message: "Nothing to search for.") }
    // Spotlight is queried in-process: the grant applies to the app, not to a spawned mdfind.
    var hits = try await Self.spotlight(words: words, fields: ["kMDItemAuthors", "kMDItemAuthorEmailAddresses", "kMDItemSubject"])
    var mode = "sender/subject"
    if hits.isEmpty {
      hits = try await Self.spotlight(words: words, fields: ["kMDItemTextContent"])
      mode = "text"
    }
    if hits.isEmpty {
      Diagnostics.log("mail.search: 0 hits for \(words)")
      return "No messages match “\(query)”."
    }
    Diagnostics.log("mail.search: \(hits.count) hits by \(mode) for \(words)")
    // Rank: more query words matched in sender/subject first, then newest.
    let ranked = hits.map { h -> (MailHit, Int) in
      let hay = (h.from + " " + h.subject).lowercased()
      return (h, words.filter { hay.contains($0) }.count)
    }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.date > $1.0.date }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE yyyy-MM-dd HH:mm"
    var out: [String] = []
    for (i, (h, _)) in ranked.prefix(limit).enumerated() {
      let body = Self.body(ofEmlx: h.path)
      out.append("--- message \(i + 1)\nfrom: \(h.from)\ndate: \(f.string(from: h.date))\nsubject: \(h.subject)\n\(body)")
    }
    return out.joined(separator: "\n")
  }

  struct MailHit {
    let path: String
    let from: String
    let subject: String
    let date: Date
  }

  /// One NSMetadataQuery over ~/Library/Mail; any word may match any of the given fields.
  @MainActor
  private static func spotlight(words: [String], fields: [String]) async throws -> [MailHit] {
    var clauses: [NSPredicate] = []
    for w in words {
      for field in fields { clauses.append(NSPredicate(format: "%K CONTAINS[cd] %@", field, w)) }
    }
    let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      NSPredicate(format: "kMDItemContentType == %@", "com.apple.mail.emlx"),
      NSCompoundPredicate(orPredicateWithSubpredicates: clauses),
    ])
    let query = NSMetadataQuery()
    query.predicate = predicate
    query.searchScopes = [URL(fileURLWithPath: mailRoot)]
    query.sortDescriptors = [NSSortDescriptor(key: "kMDItemContentCreationDate", ascending: false)]
    return try await withCheckedThrowingContinuation { continuation in
      var done = false
      var observer: NSObjectProtocol? = nil
      func finish(_ result: Result<[MailHit], Error>) {
        guard !done else { return }
        done = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        query.stop()
        continuation.resume(with: result)
      }
      observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { _ in
        query.disableUpdates()
        var hits: [MailHit] = []
        for i in 0..<min(query.resultCount, 60) {
          guard let item = query.result(at: i) as? NSMetadataItem, let path = item.value(forAttribute: "kMDItemPath") as? String else { continue }
          let authors = (item.value(forAttribute: "kMDItemAuthors") as? [String])?.joined(separator: ", ") ?? ""
          let addresses = (item.value(forAttribute: "kMDItemAuthorEmailAddresses") as? [String])?.joined(separator: ", ") ?? ""
          let subject = item.value(forAttribute: "kMDItemSubject") as? String ?? ""
          let date = item.value(forAttribute: "kMDItemContentCreationDate") as? Date ?? .distantPast
          let from = addresses.isEmpty ? authors : (authors.isEmpty ? addresses : "\(authors) <\(addresses)>")
          hits.append(MailHit(path: path, from: from, subject: subject, date: date))
        }
        finish(.success(hits))
      }
      if !query.start() { finish(.failure(BridgeError(message: "Spotlight query could not start"))) }
      DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish(.failure(BridgeError(message: "Mail search timed out"))) }
    }
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
