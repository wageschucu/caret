# Native macOS host

Status: specification, 2026-09-24. Supersedes the "host is an open question" note in `implementation.md`.

The host is a Swift menu-bar app that makes Caret work in any application, at the caret. It owns three things the Node helper cannot: reading context from other apps, intercepting keys globally, and drawing at the caret. Everything else — routing, thresholds, the permission gate, the executor, logs, eval — stays in the helper and is reached over the existing loopback HTTP API. The browser page in `public/` remains as a development host and reference client.

## Responsibilities

| Concern | Mechanism | Notes |
| --- | --- | --- |
| Focused field text and caret | `AXUIElementCreateSystemWide` → `kAXFocusedUIElementAttribute` → `kAXValueAttribute`, `kAXSelectedTextRangeAttribute` | The value is the **buffer**. Only text before the caret is sent while typing. |
| Caret screen position | `kAXBoundsForRangeParameterizedAttribute` on the selected range | Falls back to the field's frame bottom-left when unsupported. |
| Selection | `kAXSelectedTextAttribute` | Fills `selection`. |
| App and window | `NSWorkspace.frontmostApplication`, `kAXTitleAttribute` of the focused window | Fills `active_app`, `window_title`. Bundle id is used for the deny list. |
| Recent screens | On every focus change (`kAXFocusedWindowChangedNotification`, app activation), read the focused window's visible text and push `{t, app, window_title, text}` into a 4-entry in-memory ring | Fills `screens`. Never written to disk. |
| Secure fields | `kAXSubroleAttribute == kAXSecureTextFieldSubrole` | The host sends `secure: true` and **no buffer**. This satisfies the spec's rule that secure fields are excluded at the host layer, not by regex. |
| Deny list | Bundle ids from the host's settings | Sent as `deny_apps`; the helper also refuses them. |
| Key capture | `CGEvent.tapCreate` at `.cgSessionEventTap`, `.headInsertEventTap` | Tab, Esc, Ctrl-→ / Alt-→, ↑, ↓ are swallowed **only while the overlay is visible**. Every other key passes through untouched. Enter is never captured. |
| Overlay | Borderless, non-activating `NSPanel` (`.nonactivatingPanel`, level `.floating`, `ignoresMouseEvents` except on chips) | Positioned from the caret rect. Ghost text and chips are drawn here; nothing is injected into the host field until accepted. |
| Insert accepted ghost text | Set `kAXValueAttribute` / `kAXSelectedTextAttribute` when the element allows it; otherwise post keystrokes with `CGEvent(keyboardEventSource:)` | AX is preferred: atomic, no keyboard-layout issues. |
| Text results | Same insertion path, after the preview | `text.result` output is inserted at the caret. |
| Previews and slot forms | A second, activating panel | Enter confirms only inside this panel, matching the browser host. |
| Permissions | Accessibility (required), Input Monitoring (required for the event tap) | Requested once with a clear explanation; the app is inert until granted. Never asks for Screen Recording. |

## Host → helper contract

The host is an ordinary client of the helper. No helper changes are required for M1 host work.

1. `GET /api/bootstrap` at launch → session token, mode, skills with labels.
2. On each keystroke in a text field: `POST /api/complete` with `state` (streamed NDJSON ghost text).
3. On 300 ms idle or a phrase boundary: `POST /api/route` with `state` and `boundary` → `shown` chips, `event_id`.
4. Tab on a chip: `POST /api/prepare` with `event_id`, `skill`, `accepted_buffer`. Preview → `confirm` / `cancel`; missing slots → `prepare` again with `fields` and `previous_preview`.
5. Esc: `POST /api/dismiss`. Interaction timings: `POST /api/telemetry`.

`state` is the same object the browser host sends:

```json
{
  "buffer": "text before the caret",
  "active_app": "com.apple.mail",
  "window_title": "Re: flights next week",
  "url": null,
  "selection": null,
  "focused_window": "visible text of the focused window",
  "secure": false,
  "paused": false,
  "deny_apps": ["com.agilebits.onepassword7"],
  "screens": [{ "t": "2026-09-24T18:00:00Z", "app": "com.apple.Notes", "window_title": "…", "text": "…" }]
}
```

The helper trims, deduplicates, redacts, and caps this exactly as before.

## Behaviour rules carried over from the spec

- Ghost text is the baseline; a chip is an addition. Both may be visible.
- Tab accepts the highlighted chip when one is shown, else the ghost phrase. Ctrl-→ always inserts one ghost word and never executes a skill.
- Enter belongs to the host application. It never accepts a chip.
- Esc dismisses and suppresses the same skill for this buffer; the helper already implements the suppression.
- No probabilities in the overlay.
- Per-app Tab safety: terminals, IDEs and tab-navigated forms get Ctrl-Space as the accept key. The host keeps a small default list of bundle ids and a user override; the binding is printed on the chip.
- IME composition (`kAXMarkedRange` non-empty) suppresses completion and routing until composition ends.

## Host-executed tools

Some effects belong to the host, not the helper: `calendar.create` is performed through EventKit so events land in the user's real calendar; `url.open` opens the browser; `mail.draft` opens a compose window through `mailto:` (or, when the user is already writing in Mail, replaces the typed instruction with the draft body). Tools that need no preview (trusted, preview-only or reversible) are handed off at accept time; the others after confirmation. The gate does not move. On Confirm the host sends `host_tools: ["calendar.create"]`; the helper validates and consumes the single-use confirmation exactly as before, logs it, and answers `status: "host_execute"` with the validated call instead of writing a local record. The host performs it and reports `POST /api/host-executed {id, ok, error}`; Undo deletes the event through EventKit and reports `{id, undone: true}`. A host that does not claim the tool gets the M1 local JSON record as before. Calendar access is requested on first use (`NSCalendarsFullAccessUsageDescription`).

## Contacts

When the accepted skill may draft mail (`allowed-tools` includes `mail.draft`), the host extracts person names from the sentence (words after "to"/"email", capitalised words), looks them up in Contacts (`NSContactsUsageDescription`, one-time prompt) and sends up to eight "Name <address>" matches as the `contacts` field. The executor may use only those, an address the user typed, or one visible in reference material; anything else is dropped by the helper's recipient guard. Matches are never routed or logged.

## Variants (destination options)

A skill may declare `metadata.variants: "A|B|C"` and `metadata.variant_slot: "<slot>"`. While its chip is highlighted the overlay shows the options as pills; ← / → cycles them and Tab accepts chip + option, which the host sends as a slot answer. The host orders options: the one named in the sentence, then the user's profile preferences (home currencies), then the rest, leaving out the source named in the sentence. A second row, `metadata.styles: "value=Label|value=Label"` with `style_slot`, is cycled with ⌥← / ⌥→ and defaults to the Settings value (currency: value only / with rate). First use: `currency-converter` with destination currencies; the helper's `fx.convert` tool fetches the ECB reference rate (Frankfurter) so the model never invents a rate, and `currencyHints` parses amount/source/destination deterministically.

## Triggers

A skill may declare `metadata.trigger`, a case-insensitive regular expression. When it matches the typed text the helper offers that chip regardless of the router's "ready" score (the skill is boosted to 0.9 and abstain capped at 0.05 before the threshold table runs), and the routing event records `triggered`. Esc suppression still applies. First use: `currency-converter` matches bare amounts such as `250chf` or `$40`.

## Known limitations

- Apps with poor Accessibility support (some Electron apps, some web views, Java apps) may expose no value or no caret bounds. The host then degrades: buffer from typed keystrokes only, overlay anchored to the window, or nothing. It must never guess text it cannot read.
- Secure-input mode (e.g. a password prompt with `EnableSecureEventInput`) disables the event tap system-wide; the host shows nothing during it.
- Sandboxed distribution is not possible with a global event tap; the app ships unsandboxed and notarized.

## Milestones

1. **Read** — done 2026-09-24. Verified: TextEdit, Brave, Terminal, Telegram, Mail (WebKit range read). Pending: Safari, Notes, VS Code.
2. **Show** — done.
3. **Accept** — done. Key tap on its own thread so slow Accessibility reads never let the host app consume Tab.
4. **Route** — done, end to end with live Jev, local ghost text and local executor.
5. **Context** — ring buffer, deny list, secure-field exclusion and Tab-safety list are implemented; recent-window capture is off by default and not yet exercised with a skill.
6. **Host tools** — `calendar.create` through EventKit, done.

## Per-app notes (measured)

- Chromium/Electron (Brave, Claude app, VS Code): need `AXManualAccessibility`/`AXEnhancedUserInterface` set on the app element, else the focused element is the whole web area. They return a zero-height caret rect on the screen edge, which is treated as "no caret". Text replacement through Accessibility silently fails; the host selects through Accessibility and then types.
- Terminal: caret bounds work; the field is the whole window, so the buffer is the current line with the shell prompt stripped. Accept key is Ctrl-Space.
- WebKit editors (Mail compose, Notes, Safari): the web area's value is empty; text before the caret is read with `AXStringForRange`.
- macOS 14+ refuses programmatic activation of an app the user did not launch, so preview and status windows are non-activating key panels.

Location: `apps/mac/` as a Swift Package (`swift build`), with an Xcode project generated only if needed. Minimum macOS 14.
