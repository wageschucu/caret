import Foundation

/// User-adjustable host settings, persisted in UserDefaults.
enum Settings {
  private static let defaults = UserDefaults.standard

  static var helperURL: URL {
    URL(string: defaults.string(forKey: "helperURL") ?? "http://127.0.0.1:4317")!
  }

  /// Bundle identifiers whose text is never read or sent.
  static var denyApps: [String] {
    get { defaults.stringArray(forKey: "denyApps") ?? [
        "com.agilebits.onepassword7", "com.1password.1password", "com.apple.keychainaccess",
        "com.anthropic.claudefordesktop",
      ] }
    set { defaults.set(newValue, forKey: "denyApps") }
  }

  /// Apps where Tab is native (terminals, IDEs). The accept key becomes Ctrl-Space there.
  static var tabUnsafeApps: [String] {
    get {
      defaults.stringArray(forKey: "tabUnsafeApps") ?? [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode", "com.apple.dt.Xcode",
        "dev.warp.Warp-Stable", "com.jetbrains.intellij", "org.alacritty", "net.kovidgoyal.kitty",
      ]
    }
    set { defaults.set(newValue, forKey: "tabUnsafeApps") }
  }

  static var paused: Bool {
    get { defaults.bool(forKey: "paused") }
    set { defaults.set(newValue, forKey: "paused") }
  }

  /// Whether recent-window text is captured on focus changes and sent as `screens`.
  static var screenContext: Bool {
    get { defaults.object(forKey: "screenContext") as? Bool ?? false }
    set { defaults.set(newValue, forKey: "screenContext") }
  }
}
