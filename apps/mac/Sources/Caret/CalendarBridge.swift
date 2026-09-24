import EventKit
import Foundation

/// Performs `calendar.create` in the user's real calendar. The helper has already run the permission
/// gate and consumed the single-use confirmation before this is called; this only creates and deletes.
final class CalendarBridge {
  struct BridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  private let store = EKEventStore()
  private static let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  private func ensureAccess() async throws {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess: return
    case .denied, .restricted:
      throw BridgeError(message: "Calendar access is off for Caret. Enable it in System Settings → Privacy & Security → Calendars.")
    default:
      guard try await store.requestFullAccessToEvents() else {
        throw BridgeError(message: "Calendar access was not granted.")
      }
    }
  }

  /// Creates the event and returns its identifier for undo.
  func create(title: String, start: String, end: String) async throws -> (identifier: String, calendar: String) {
    try await ensureAccess()
    guard let startDate = Self.iso.date(from: start), let endDate = Self.iso.date(from: end), endDate > startDate
    else { throw BridgeError(message: "Invalid start or end time.") }
    guard let calendar = store.defaultCalendarForNewEvents else {
      throw BridgeError(message: "No default calendar is set in Calendar.app.")
    }
    let event = EKEvent(eventStore: store)
    event.title = title
    event.startDate = startDate
    event.endDate = endDate
    event.calendar = calendar
    event.notes = "Created by Caret"
    try store.save(event, span: .thisEvent, commit: true)
    return (event.eventIdentifier, calendar.title)
  }

  func delete(identifier: String) async throws {
    try await ensureAccess()
    guard let event = store.event(withIdentifier: identifier) else {
      throw BridgeError(message: "The event is no longer in the calendar.")
    }
    try store.remove(event, span: .thisEvent, commit: true)
  }
}
