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

  /// Repository root that holds the helper, embedded by build.sh; overridable in defaults.
  static var helperRepo: String? {
    defaults.string(forKey: "helperRepo") ?? Bundle.main.object(forInfoDictionaryKey: "CaretHelperRepo") as? String
  }

  /// Facts about the user for the executor (names, sign-offs, addresses). Sent only with an accept,
  /// never to the router. Keys: name, email, signature, notes, currencies.
  static var profile: [String: String] {
    // A new user starts with USD as home currency; everything else is empty until entered.
    get { ["currencies": "USD"].merging((defaults.dictionary(forKey: "profile") as? [String: String]) ?? [:]) { $1 } }
    set { defaults.set(newValue.filter { !$0.value.isEmpty }, forKey: "profile") }
  }

  static var paused: Bool {
    get { defaults.bool(forKey: "paused") }
    set { defaults.set(newValue, forKey: "paused") }
  }

  /// How tool results are rendered: "compact" (the value only) or "verbose" (with source and rate).
  static var resultStyle: String {
    get { defaults.string(forKey: "resultStyle") ?? "compact" }
    set { defaults.set(newValue, forKey: "resultStyle") }
  }

  /// Whether recent-window text is captured on focus changes and sent as `screens`.
  static var screenContext: Bool {
    get { defaults.object(forKey: "screenContext") as? Bool ?? false }
    set { defaults.set(newValue, forKey: "screenContext") }
  }
}
