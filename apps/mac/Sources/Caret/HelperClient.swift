import Foundation

/// Client for the Node helper's loopback HTTP API. Mirrors public/app.js.
final class HelperClient {
  struct Skill: Decodable {
    let slug: String
    let label: String?
    let description: String
    let side_effect_class: String
    let active: Bool
  }
  struct Bootstrap: Decodable {
    let token: String
    let mode: String
    let executor: String
    let problems: [String]?
    let warning: String?
    let skills: [Skill]
  }
  struct RouteResult: Decodable {
    let event_id: String
    let shown: [String]
    let propose: Bool?
    let mode: String
    let warning: String?
  }
  struct SkillDraft: Decodable {
    let name: String
    let label: String
    let markdown: String
    let demo: Bool?
  }
  struct SavedSkill: Decodable {
    let slug: String
    let label: String?
    let trust: String
  }
  struct Completion: Decodable {
    let text: String?
    let mode: String?
    let phrase_boundary: Bool?
    let error: String?
  }
  /// Preview or done. Fields are optional because the helper returns one of two shapes.
  struct Execution {
    let status: String
    let id: String?
    let skill: String
    let preview: String?
    let missingSlots: [String]
    let calls: [[String: Any]]
    let requiresConfirmation: Bool
    let demo: Bool
    let result: String?
    let undoID: String?
  }
  struct HelperError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  private let base: URL
  private let session: URLSession
  private(set) var token = ""
  private(set) var skills: [Skill] = []

  init(base: URL) {
    self.base = base
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    session = URLSession(configuration: config)
  }

  func label(for slug: String) -> String {
    skills.first { $0.slug == slug }?.label ?? slug
  }

  func skill(_ slug: String) -> Skill? { skills.first { $0.slug == slug } }

  func bootstrap() async throws -> Bootstrap {
    let (data, response) = try await session.data(from: base.appendingPathComponent("api/bootstrap"))
    try check(response, data)
    let boot = try JSONDecoder().decode(Bootstrap.self, from: data)
    token = boot.token
    skills = boot.skills
    return boot
  }

  private func request(_ endpoint: String, _ body: [String: Any]) throws -> URLRequest {
    var request = URLRequest(url: base.appendingPathComponent("api/\(endpoint)"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(token, forHTTPHeaderField: "X-SkillRouter-Session")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  private func check(_ response: URLResponse, _ data: Data) throws {
    guard let http = response as? HTTPURLResponse else { throw HelperError(message: "No response from helper") }
    if http.statusCode >= 400 {
      let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
      throw HelperError(message: message ?? "Helper error \(http.statusCode)")
    }
  }

  /// POSTs, and when the helper has restarted (session unknown → 403) bootstraps again and retries once.
  private func post(_ endpoint: String, _ body: [String: Any]) async throws -> Data {
    var (data, response) = try await session.data(for: try request(endpoint, body))
    if (response as? HTTPURLResponse)?.statusCode == 403 {
      Diagnostics.log("session rejected on /api/\(endpoint); re-bootstrapping")
      _ = try await bootstrap()
      (data, response) = try await session.data(for: try request(endpoint, body))
    }
    try check(response, data)
    return data
  }

  private func postJSON(_ endpoint: String, _ body: [String: Any]) async throws -> [String: Any] {
    let data = try await post(endpoint, body)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  func route(state: [String: Any], boundary: Int) async throws -> RouteResult {
    try JSONDecoder().decode(RouteResult.self, from: try await post("route", ["state": state, "boundary": boundary]))
  }

  /// Streams ghost-text updates (NDJSON). Ends at the helper's phrase/token/time limit or on cancellation.
  func complete(state: [String: Any]) -> AsyncThrowingStream<Completion, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let (bytes, response) = try await session.bytes(for: try request("complete", ["state": state]))
          try check(response, Data())
          for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            let chunk = try JSONDecoder().decode(Completion.self, from: data)
            if let error = chunk.error { throw HelperError(message: error) }
            continuation.yield(chunk)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func dismiss(buffer: String, eventID: String?) async {
    _ = try? await post("dismiss", ["buffer": buffer, "event_id": eventID ?? NSNull()])
  }

  func telemetry(_ action: String, eventID: String?, latencyMs: Double? = nil) {
    Task {
      _ = try? await post(
        "telemetry", ["action": action, "event_id": eventID ?? NSNull(), "latency_ms": latencyMs ?? NSNull()])
    }
  }

  /// Tools this host performs itself; the helper hands them over after running its gate.
  static let hostTools = ["calendar.create", "url.open", "mail.draft"]

  func prepare(eventID: String, skill: String, buffer: String, fields: [String: String], previous: String?)
    async throws -> Execution
  {
    var body: [String: Any] = [
      "event_id": eventID, "skill": skill, "accepted_buffer": buffer, "fields": fields, "host_tools": Self.hostTools,
      "profile": Settings.profile,
    ]
    if let previous { body["previous_preview"] = previous }
    return Self.execution(try await postJSON("prepare", body))
  }

  /// `hostTools` are tools this host performs itself; the helper then returns status "host_execute".
  func debug() async throws -> [String: Any] { try await postJSON("debug", [:]) }
  func rollback(to hash: String) async throws -> [String: Any] {
    try await postJSON("registry/rollback", ["registry_hash": hash])
  }

  func propose(eventID: String) async throws -> SkillDraft {
    try JSONDecoder().decode(SkillDraft.self, from: try await post("propose", ["event_id": eventID]))
  }
  func createSkill(markdown: String) async throws -> SavedSkill {
    try JSONDecoder().decode(SavedSkill.self, from: try await post("skills", ["markdown": markdown]))
  }

  func confirm(id: String, hostTools: [String] = HelperClient.hostTools) async throws -> Execution {
    Self.execution(try await postJSON("confirm", ["id": id, "host_tools": hostTools]))
  }
  func reportHostExecution(id: String, ok: Bool, error: String? = nil, undone: Bool = false) async throws {
    _ = try await post("host-executed", ["id": id, "ok": ok, "error": error ?? NSNull(), "undone": undone])
  }
  func cancel(id: String) async { _ = try? await post("cancel", ["id": id]) }
  func undo(id: String) async throws { _ = try await post("undo", ["id": id]) }

  private static func execution(_ json: [String: Any]) -> Execution {
    Execution(
      status: json["status"] as? String ?? "",
      id: json["id"] as? String,
      skill: json["skill"] as? String ?? "",
      preview: json["preview"] as? String,
      missingSlots: json["missing_slots"] as? [String] ?? [],
      // A preview carries `calls`; a host handoff carries the single validated `call`.
      calls: (json["calls"] as? [[String: Any]]) ?? (json["call"] as? [String: Any]).map { [$0] } ?? [],
      requiresConfirmation: json["requires_confirmation"] as? Bool ?? false,
      demo: json["demo"] as? Bool ?? false,
      result: json["result"] as? String,
      undoID: json["undo_id"] as? String)
  }
}
