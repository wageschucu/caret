# SkillRouter

A local, keyboard-first implementation of the **M1 core loop** from [SKILLROUTER_v3.md](SKILLROUTER_v3.md). The original PDF is preserved. The Markdown conversion includes all 24 numbered sections, reconstructed tables, code samples, and an architecture diagram.

## Run

Requires Node.js 22 or newer.

```sh
npm install
npm start
```

Open **http://127.0.0.1:4317**. Without credentials, the app clearly identifies itself as a local demo. Demo routing uses simple rules and demo writing supports a few examples; it is not Jev or a general-purpose language model. Saving files and creating local calendar records are real local operations, even in demo mode.

Try:

- `translate into Spanish: hello` → Tab → “Hola”.
- `draft an email thanking the team for their help` → Tab → a demo draft.
- `schedule a meeting tomorrow` → Tab → enter title and ISO start/end times → review → confirm.
- `save notes as meeting.md: Review the design on Friday` → Tab → a new file with session undo.
- `thank you` → ghost phrase → Ctrl+Right to accept a word, or Tab to accept the phrase.

Calendar actions create records in **SkillRouter’s local calendar folder**. They do not connect to Google/Outlook calendars or send invitations. Web search returns a clickable search link; it does not claim to retrieve results.

## Connect live models

Copy `.env.example` to `.env` and set:

```dotenv
TYPESAFE_API_KEY=your-key
JEV_MODEL=jev-1.13.0
LLM_BASE_URL=http://127.0.0.1:11434/v1
LLM_MODEL=your-installed-model
COMPLETER_MODEL=your-fast-installed-model
```

`LLM_BASE_URL` must provide an OpenAI-compatible `/chat/completions` endpoint with streaming and JSON-object output support. For a hosted endpoint, also set `LLM_API_KEY`. These variables are read only by the helper; credentials never enter the browser. Restart after changing `.env` or skills. No models are downloaded or configured automatically.

The completer streams a phrase, stops at punctuation or 30 tokens, and cancels at a 200 ms deadline. A cold or slow model may return no ghost text within that budget. Use a warm, fast model. No latency or live accuracy claim has been validated yet.

## Controls

| Context | Key | Result |
| --- | --- | --- |
| Ghost text | Tab | Insert ghost phrase |
| Ghost text or chip | Ctrl+Right | Insert next ghost word; never execute a skill |
| Action chips | Tab | Accept highlighted skill |
| Two chips | Up / Down | Change highlight |
| Typing | Esc | Dismiss chips and ghost text |
| Preview | Enter in card / second Tab | Confirm an action once all slots are filled |
| Preview | Esc | Cancel and return to typing |
| Host conflicts | Ctrl+Space | Alternate accept binding, selectable in context settings |

If the OS reserves Ctrl+Right (for example for switching desktops), Alt+Right also accepts the next ghost word. Enter never accepts the first chip. Inputs using IME composition do not trigger completion or routing until composition ends.

## Privacy and permissions

Screen context is off by default. The context settings support pasted focused-window text, selected text, an app deny list, and pause. Optional Screenpipe integration requires both `SCREENPIPE_ENABLED=true` and the UI’s screen-context checkbox. It requests recent accessibility text with OCR fallback. It never fetches screenshots or audio. Screenpipe’s own continuous recording and secure-field exclusions must be configured in Screenpipe; this browser host does not control OS capture.

The helper trims/deduplicates context, removes common secret patterns, and caps serialized state at 4,000 UTF-8 bytes as a conservative token bound. A secure or denied host field returns empty state. Only a skill’s declared context reaches the executor. Screen text is labeled untrusted reference data.

The application, not the model, owns permissions. Tool effects cannot be downgraded by skill metadata. Sends/pays and destructive classes require an exact preview and a single-use confirmation. Reviewed skills force preview; untrusted skills cannot access side-effecting tools. Arbitrary scripts and shell commands are unavailable in this M1 build.

Local files are created exclusively without overwriting existing files. Undo only removes an unchanged result from the same session. The server binds to loopback and validates Host, Origin, JSON content type, and a per-session token. It is a local application, not an internet-facing service.

## Skills and data

- `skills/<slug>/SKILL.md`: eight bundled skills. Override `metadata.active` with the string `"false"` to disable a skill, then restart.
- `.skillrouter/events.jsonl`: local redacted routing states, interaction events, and execution events.
- `.skillrouter/registries/`: full registry snapshots keyed by hash for historical reconstruction.
- `.skillrouter/output/files/`: new local text files.
- `.skillrouter/output/calendar/`: local event JSON records.

No telemetry sync or upload is implemented. Local logs contain redacted content, not just counters; treat them as personal data. A session and its undo handles end when the helper restarts. Existing outputs remain on disk.

## Verify and evaluate

```sh
npm test
npm run eval -- --out eval/demo-report.json
npm run metrics
```

The tests cover thresholds, hysteresis, suppression, redaction, context scoping, trust/effect enforcement, tool validation, streaming, and HTTP execution/confirmation/undo. Tests use temporary directories and do not call model services.

The 22 seed evaluation states are **synthetic smoke fixtures**, not proof of model quality. To evaluate Jev against the current registry:

```sh
npm run eval -- --live --out eval/live-report.json
npm run eval -- --live --baseline eval/live-report.json --out eval/candidate-report.json
```

Live evaluation makes billable Jev requests. A baseline comparison exits unsuccessfully when false-route rate, missed-route rate, or wrong-route count increases. Baselines require an identical labeled dataset and evaluation mode. Edit descriptions only after comparing a candidate report; automatic editing is not enabled.

Add hand-checked JSONL entries with `state`, `label` (a skill slug or `NO_ROUTE`), and `language`. A recorded routing event can also be copied and labeled; its probabilities replay offline when its registry hash matches. Registry/model/description changes require `--live` to obtain fresh probabilities. The report includes a confusion matrix, false and missed-route rates, abstention calibration bins, and per-language counts. Grow this set toward the spec’s 300+ real states.

## Implementation boundary

This is an M1 implementation and a usable local prototype. It does **not** implement the PDF’s M2/M3 proposal authoring, catalog adoption, script sandbox, rollback UI, multi-device sync, voice input, or an OS/browser-extension host. Active registries over 254 skills fail explicitly rather than silently dropping options. See [implementation notes](docs/implementation.md) for API corrections and remaining validation.
