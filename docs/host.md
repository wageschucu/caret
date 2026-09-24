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

Some effects belong to the host, not the helper: `calendar.create` is performed through EventKit so events land in the user's real calendar. The gate does not move. On Confirm the host sends `host_tools: ["calendar.create"]`; the helper validates and consumes the single-use confirmation exactly as before, logs it, and answers `status: "host_execute"` with the validated call instead of writing a local record. The host performs it and reports `POST /api/host-executed {id, ok, error}`; Undo deletes the event through EventKit and reports `{id, undone: true}`. A host that does not claim the tool gets the M1 local JSON record as before. Calendar access is requested on first use (`NSCalendarsFullAccessUsageDescription`).

## Known limitations

- Apps with poor Accessibility support (some Electron apps, some web views, Java apps) may expose no value or no caret bounds. The host then degrades: buffer from typed keystrokes only, overlay anchored to the window, or nothing. It must never guess text it cannot read.
- Secure-input mode (e.g. a password prompt with `EnableSecureEventInput`) disables the event tap system-wide; the host shows nothing during it.
- Sandboxed distribution is not possible with a global event tap; the app ships unsandboxed and notarized.

## Milestones

1. **Read**: menu-bar app, permission prompts, AX reader that logs `state` for the focused field. Verify in TextEdit, Safari, Mail, Notes, VS Code, Terminal.
2. **Show**: overlay panel at the caret with demo ghost text from the helper.
3. **Accept**: event tap; Tab inserts ghost text; Esc dismisses.
4. **Route**: chips, ↑/↓, Tab → preview panel → confirm; `translate hello into Spanish` works end to end in TextEdit.
5. **Context**: focus-change ring buffer, deny list, secure-field exclusion, Tab-safety list.

Location: `apps/mac/` as a Swift Package (`swift build`), with an Xcode project generated only if needed. Minimum macOS 14.
