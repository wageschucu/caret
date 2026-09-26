import Contacts
import Foundation

/// Resolves names mentioned in a sentence to e-mail addresses from the user's Contacts.
/// Matches are passed to the local executor as reference data; they never reach the router or logs.
final class ContactsBridge {
  private let store = CNContactStore()
  private static let stopWords: Set<String> = [
    "draft", "write", "send", "email", "mail", "message", "reply", "to", "for", "about", "thanking", "thank",
    "her", "him", "them", "the", "a", "an", "and", "with", "regarding", "re", "asking", "telling", "please",
    "i", "me", "my", "we", "our", "you", "your", "it", "this", "that", "of", "on", "in", "at", "from", "by",
  ]

  /// Candidate person names: capitalised words, and the words right after "to"/"email"/"mail".
  static func names(in sentence: String) -> [String] {
    var found: [String] = []
    let words = sentence.split(whereSeparator: { !$0.isLetter && $0 != "-" && $0 != "'" }).map(String.init)
    for (i, word) in words.enumerated() {
      let lower = word.lowercased()
      if stopWords.contains(lower) || word.count < 2 { continue }
      let afterCue = i > 0 && ["to", "email", "mail", "message", "ping"].contains(words[i - 1].lowercased())
      let capitalised = word.first!.isUppercase && i > 0
      if afterCue || capitalised {
        // Join a following capitalised word as a surname.
        var name = word
        if i + 1 < words.count, words[i + 1].first!.isUppercase, !stopWords.contains(words[i + 1].lowercased()) {
          name += " " + words[i + 1]
        }
        if !found.contains(name) { found.append(name) }
      }
    }
    return Array(found.prefix(4))
  }

  private func ensureAccess() async throws -> Bool {
    switch CNContactStore.authorizationStatus(for: .contacts) {
    case .authorized, .limited: return true
    case .denied, .restricted: return false
    default: return (try? await store.requestAccess(for: .contacts)) ?? false
    }
  }

  /// "Full Name <address>" lines for contacts whose name matches, at most three per name.
  func lookup(_ names: [String]) async -> [String] {
    guard !names.isEmpty, (try? await ensureAccess()) == true else { return [] }
    let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
    var lines: [String] = []
    for name in names {
      let predicate = CNContact.predicateForContacts(matchingName: name)
      var contacts = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
      if contacts.filter({ !$0.emailAddresses.isEmpty }).isEmpty {
        // Apple's matcher ignores nicknames and needs a prefix; scan given, family and nickname ourselves.
        let needle = name.lowercased()
        var scanned: [CNContact] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { c, stop in
          if c.emailAddresses.isEmpty { return }
          let fields = [c.givenName, c.familyName, c.nickname].map { $0.lowercased() }
          if fields.contains(where: { $0.hasPrefix(needle) || $0.contains(" " + needle) || $0 == needle }) {
            scanned.append(c)
            if scanned.count >= 3 { stop.pointee = true }
          }
        }
        contacts = scanned
      }
      for contact in contacts.prefix(3) where !contact.emailAddresses.isEmpty {
        let full = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        for email in contact.emailAddresses.prefix(2) {
          let line = "\(full) <\(email.value as String)>"
          if !lines.contains(line) { lines.append(line) }
        }
      }
    }
    return Array(lines.prefix(8))
  }
}
