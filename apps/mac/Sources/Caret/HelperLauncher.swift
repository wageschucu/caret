import Foundation
import ServiceManagement

/// Starts the Node helper from the repository when it is not already running, and manages
/// launch-at-login for the app. The helper's output goes to ~/Library/Logs/Caret/helper.log.
@MainActor
final class HelperLauncher {
  private var process: Process?
  private(set) var attempted = false

  var isRunning: Bool { process?.isRunning ?? false }

  /// Launches `npm start` through a login shell so the user's Node (Homebrew, nvm, …) is found.
  func start() -> Bool {
    guard !attempted, let repo = Settings.helperRepo,
      FileManager.default.fileExists(atPath: repo + "/src/server.js")
    else { return false }
    attempted = true
    let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Caret")
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let log = logs.appendingPathComponent("helper.log")
    if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
    let handle = try? FileHandle(forWritingTo: log)
    handle?.seekToEndOfFile()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", "cd " + shellQuote(repo) + " && exec node --env-file-if-exists=.env src/server.js"]
    p.standardOutput = handle
    p.standardError = handle
    p.terminationHandler = { [weak self] proc in
      Diagnostics.log("helper exited with status \(proc.terminationStatus)")
      Task { @MainActor in
        guard let self else { return }
        self.process = nil
        // A helper this app started is brought back unless the app itself is stopping it.
        if !self.stopping {
          try? await Task.sleep(for: .seconds(1))
          self.attempted = false
          if self.start() { Diagnostics.log("helper restarted after exit") }
        }
      }
    }
    do {
      try p.run()
      process = p
      Diagnostics.log("helper started from \(repo) (pid \(p.processIdentifier))")
      return true
    } catch {
      Diagnostics.log("helper launch failed: \(error.localizedDescription)")
      return false
    }
  }

  /// Allows another start after the helper died or was stopped.
  func reset() {
    attempted = false
    process = nil
  }

  /// Stops a helper this app started; one started by the user is left alone.
  private var stopping = false

  func stop() {
    stopping = true
    process?.terminate()
    process = nil
  }

  private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

  // MARK: - Launch at login

  static var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

  static func setLaunchAtLogin(_ on: Bool) throws {
    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
  }
}
