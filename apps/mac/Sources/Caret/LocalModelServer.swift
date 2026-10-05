import Foundation

/// Ollama's server for ghost text and the local executor. When nothing answers on Ollama's port,
/// Caret starts the server from Ollama.app itself (no Ollama window or menu-bar app) and stops it
/// when Caret quits, so no model process outlives Caret. A server started by someone else, such
/// as Ollama.app, is used and left alone.
@MainActor
final class LocalModelServer {
  static let binary = "/Applications/Ollama.app/Contents/Resources/ollama"
  private static let probe = URL(string: "http://127.0.0.1:11434/api/version")!
  private var process: Process?
  private var checked = false

  func startIfNeeded() async {
    guard !checked else { return }
    checked = true
    guard FileManager.default.isExecutableFile(atPath: Self.binary), !(await Self.isUp()) else { return }
    let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Caret")
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let log = logs.appendingPathComponent("ollama.log")
    if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
    let handle = try? FileHandle(forWritingTo: log)
    handle?.seekToEndOfFile()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: Self.binary)
    p.arguments = ["serve"]
    p.standardOutput = handle
    p.standardError = handle
    do {
      try p.run()
      process = p
      Diagnostics.log("started Ollama server (pid \(p.processIdentifier))")
    } catch {
      Diagnostics.log("could not start Ollama server: \(error.localizedDescription)")
      return
    }
    // Wait briefly so the helper finds the models on its first try.
    for _ in 0..<25 {
      if await Self.isUp() { return }
      try? await Task.sleep(for: .milliseconds(200))
    }
  }

  /// Stops a server this app started; `ollama serve` stops its model runners with it.
  func stop() {
    guard let p = process, p.isRunning else { return }
    p.terminate()
    process = nil
    Diagnostics.log("stopped Ollama server")
  }

  private static func isUp() async -> Bool {
    var request = URLRequest(url: probe)
    request.timeoutInterval = 0.5
    guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
    return (response as? HTTPURLResponse)?.statusCode == 200
  }
}
