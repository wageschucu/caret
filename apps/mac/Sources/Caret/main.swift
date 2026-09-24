import AppKit

// Menu-bar host for the Caret helper. See docs/host.md for the contract.
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
