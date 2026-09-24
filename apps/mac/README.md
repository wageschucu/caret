# Caret for macOS

The native host that makes Caret work in any application, at the caret. Spec: [docs/host.md](../../docs/host.md).

## Build and run

Requires macOS 14+ and the Xcode Command Line Tools (Swift 5.9+). Xcode itself is not needed.

```sh
npm install               # once, from the repository root
apps/mac/build.sh --run   # builds build/Caret.app and launches it
```

The app starts the helper itself (`node src/server.js` from the repository path embedded at build time, log in `~/Library/Logs/Caret/helper.log`) when nothing answers on the helper port, and stops it on quit. A helper you started by hand with `npm start` is used as is. "Launch Caret at login" in the menu registers the app as a login item.

On first launch macOS asks for **Accessibility** permission (System Settings → Privacy & Security → Accessibility). Caret is inert until it is granted. The app shows a Dock icon (its menu mirrors the menu-bar one, since a notch can hide menu-bar icons) and a status window whenever it needs attention; clicking the Dock icon opens that window.

### Keeping the grant across rebuilds

macOS ties the grant to the app's code signature. With the default ad-hoc signature every rebuild is a new signature, so the switch in System Settings stays on but no longer applies; remove Caret from the list and add `apps/mac/build/Caret.app` again (or run `tccutil reset Accessibility com.paulgettel.caret` and relaunch).

To avoid that, sign with a stable identity once:

1. Keychain Access → Certificate Assistant → Create a Certificate… Name `Caret Dev`, Identity Type *Self Signed Root*, Certificate Type *Code Signing*.
2. Build as usual: `build.sh` uses a certificate named `Caret Dev` automatically when it exists (`CARET_SIGN_IDENTITY` overrides the name).

The first launch after switching identities needs one more grant; after that rebuilds keep it.

## What it does

- Reads the focused text field, caret, selection, app and window title through the Accessibility API. Secure fields and deny-listed apps are skipped before anything is read.
- Sends the text before the caret to the helper on every keystroke (ghost text) and after a 300 ms pause or at punctuation (routing), exactly like the browser host.
- Draws ghost text and action chips in a floating panel under the caret. Tab accepts (Ctrl-Space in terminals and IDEs), Ctrl-→ or ⌥-→ takes one ghost word, ↑/↓ cycles chips, Esc dismisses. Enter is never intercepted.
- Opens a preview window for anything that needs slots or confirmation. Text results are inserted at the caret; file and calendar results show a panel with Undo.

Recent-window context is **off** by default (menu → "Include recent windows as context"). When on, the visible text of the focused window is captured in memory on focus changes and sent as `screens`; nothing is written to disk.

## Debugging

- Menu → "Copy last state (debug)" copies the JSON the host last sent to the helper.
- `swift run` from `apps/mac` runs the app unbundled with stderr in the terminal; note that Accessibility trust is then tied to the debug binary path.
- `swift build` alone compiles without producing the bundle.

## Known limitations

Apps with weak Accessibility support (some Electron apps, Java apps, some web views) may report no caret bounds or no value; the overlay then anchors to the field or stays hidden. Password prompts that enable secure event input disable the key tap system-wide for their duration.
