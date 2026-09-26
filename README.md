# Caret

Caret finishes your sentences and does the small things you were about to do. While you type in any Mac app, it shows the next phrase in grey. When it can tell what you want, it shows one action: translate, draft the reply, put it on the calendar, save the note. Tab takes it. Nothing runs until you have seen exactly what will happen and said yes.

## Quick start (macOS 14+)

```sh
npm install
apps/mac/build.sh --run
```

Grant Accessibility when asked. Then type in any app:

- `translate into Spanish: hello` → Tab → `Hola`
- `schedule a design review tomorrow at 3` → Tab → preview → confirm → event in your calendar
- `draft an email thanking the team` → Tab → draft opens in your mail client
- `thank you` → ghost phrase appears → Tab accepts it, Ctrl+→ takes one word

Out of the box Caret runs in demo mode with rule-based routing and a few canned results. See [Connect live models](#connect-live-models) to make it real.

## What it does

- **Completes** the phrase you are typing, inline, in grey. Accept it or keep typing.
- **Offers one action** when it is confident about what you want. Never from what is on screen alone.
- **Shows you first.** Anything that sends, pays, or writes shows the exact call and waits for a single confirmation. Files can be undone in the same session.
- **Reads only what you allow.** The field you are in, your selection, and optionally the last few windows. Password fields and apps on your deny list are never read.

## Skills

| Say | Skill | What happens |
| --- | --- | --- |
| translate … into French | translate | Text inserted at the caret |
| make this more professional | rewrite | Text inserted at the caret |
| summarize what I was reading | summarize-selection | Uses your selection or the last window |
| extract action items from that | extract-action-items | Bulleted list inserted |
| draft a reply thanking Sam | draft-email | Compose window, or in place in your mail client |
| schedule a meeting Friday 2pm | calendar-event | Event in your calendar via EventKit, no invitations |
| 250 chf in usd | currency-converter | ECB rate from frankfurter.app; only the amount and codes are sent |
| save these notes as todo.md | file-save | New file only, never overwrites, undo in session |
| search for quiet keyboards | web-search | Opens the search in your browser |

When Caret twice declines something it could have done, ⌘⇧N drafts a new skill for you to review.

### Lookups

Some skills may look things up while planning, before the one gated action: read-only, at most three per accept, only for skills that list them, each logged. `draft an email to the contributors of this repo` finds the addresses through your own `gh` login; `reply to Sam's message about the invoice` finds the message in Mail; `schedule a meeting with Sam tomorrow afternoon` reads your calendar and proposes the first free hour; names in a sentence resolve through Contacts. Details in [docs/host.md](docs/host.md).

## Connect live models

Real behavior comes from three model roles. Set them up in any order; each falls back to demo on its own when unset. If Ollama is running, the two local roles configure themselves from whatever models you already have.

| Role | What it does | Needs | Without it |
| --- | --- | --- | --- |
| Router | Decides whether to offer an action, and which | TypeSafe Jev key | Keyword rules, English only |
| Executor | Writes the draft, translation, summary | Anthropic API (recommended, ~2 s) or a local model | Canned examples for a few phrases |
| Completer | Ghost text while you type | A small, fast local model | Fixed demo phrases |

### 1. Local models (completer, and executor fallback)

Install the [Ollama app](https://ollama.com/download) and pull one model for each role. Caret never downloads models for you.

```sh
ollama pull llama3.2:1b    # completer, 1.3 GB, fast enough for ghost text
ollama pull llama3.1:8b    # executor fallback, 4.9 GB, 2 to 9 s per draft on an M2
```

That is all the local setup. At startup the helper asks Ollama which models are pulled and uses the smallest for ghost text and the largest for the executor, unless you name models in `.env`. The startup log says which it chose. Set `OLLAMA_AUTODETECT=false` to turn this off.

Use the official app, not a Homebrew build, which may run CPU-only. Any other OpenAI-compatible endpoint works for the executor; set `LLM_API_KEY` too if it is hosted.

### 2. Hosted executor (recommended)

Drafts, summaries and lookups run 5 to 8 times faster on the Anthropic API: translate 1.6 s instead of 12 s, a reply with a mail lookup about 4 s instead of 20 s. Set `EXECUTOR_PROVIDER=anthropic`, `LLM_MODEL=claude-haiku-4-5` and `ANTHROPIC_API_KEY` (or log in once with `ant auth login`). If the API is unavailable (no credits, offline) the helper falls back to the local model and says so in Caret's status line. Only the accepted request, its declared context and lookup results go to the API; ghost text and routing state never do. Any OpenAI-compatible endpoint also works via `LLM_BASE_URL` and `LLM_API_KEY`.

### 3. Jev key (router)

Get a TypeSafe API key. Without it Caret still runs but routes by keywords.

### 4. Write `.env`

```sh
cp .env.example .env
```

```dotenv
TYPESAFE_API_KEY=your-key
EXECUTOR_PROVIDER=anthropic   # hosted executor; leave empty to run the executor locally
ANTHROPIC_API_KEY=your-key
LLM_MODEL=claude-haiku-4-5    # with EXECUTOR_PROVIDER=anthropic; a local model name otherwise
LLM_FALLBACK_MODEL=llama3.1:8b
COMPLETER_BUDGET_MS=800      # spec target is 200; a 1B model on an M2 needs about 800
# Only if you want to override what Ollama detection picked, or use another endpoint:
LLM_BASE_URL=http://127.0.0.1:11434/v1
LLM_MODEL=llama3.1:8b
COMPLETER_MODEL=llama3.2:1b
```

`.env` is gitignored and read only by the helper. Credentials never reach the host app or a browser. Restart the helper after changing it: quit and relaunch Caret, or Ctrl+C and `npm start` again.

### 5. Check it took

Type a sentence in any app. Ghost text within a second means the completer is live. A chip on `translate into French: hello` means the router is live. Accepting it and getting `Bonjour` rather than a demo notice means the executor is live.

The startup log names the models in use, or says `Ollama is not running` when it fell back to demo. If the router silently stays in demo mode, look for `Routing uses demo rules` in `~/Library/Logs/Caret/helper.log` or the terminal. A rejected key logs once and the session continues on rules. If the documented Jev endpoint returns 401, set `JEV_ENDPOINT` to the one your account uses.

The first request to a cold Ollama model is slow. Type a throwaway sentence to warm it up.

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
| Terminals and IDEs | Ctrl+Space | Alternate accept binding, per app in Settings |
| Chip with options | ← / → | Choose an option, e.g. the currency to convert to |
| Chip with a style row | ⌥← / ⌥→ | Choose the result style, e.g. value only or with rate |
| No skill fits | ⌘⇧N | Draft a new skill from the sentence |

If the OS reserves Ctrl+Right (for example for switching desktops), Alt+Right also accepts the next ghost word. Enter never accepts the first chip. Inputs using IME composition do not trigger completion or routing until composition ends.

## Privacy and permissions

Screen context is supplied by the host, never fetched by the helper. The native macOS host reads the focused field, selection, and recent windows through the Accessibility API (see [docs/host.md](docs/host.md)). The browser host has no access to other windows; its context settings support pasted focused-window text, selected text, an app deny list, and pause. Screenpipe was removed on 2026-09-24: it is unnecessary once the host has Accessibility access, and its continuous recording is costly.

The helper trims/deduplicates context, removes common secret patterns, and caps serialized state at 8,000 UTF-8 bytes as a conservative token bound. A secure or denied host field returns empty state. Only a skill's declared context reaches the executor. Screen text is labeled untrusted reference data.

The application, not the model, owns permissions. Tool effects cannot be downgraded by skill metadata. Sends/pays and destructive classes require an exact preview and a single-use confirmation. Reviewed skills force preview; untrusted skills cannot access side-effecting tools. Arbitrary scripts and shell commands are unavailable in this build.

### What leaves your Mac

- **Routing (Jev, TypeSafe):** the text before the caret plus trimmed context, on each pause in typing, when a key is set.
- **Executor (Anthropic API):** only when you accept a chip: the sentence, the context the skill declares, your profile facts and lookup results.
- **Currency:** the amount and the two currency codes, to frankfurter.app.
- **GitHub lookups:** read-only API calls through your own `gh` login.
- Ghost text, the mail index, Contacts and calendar data stay on the machine; the mail search needs Full Disk Access and sends at most three matched messages' text to the executor for that request.

Local files are created exclusively without overwriting existing files. Undo only removes an unchanged result from the same session. The server binds to loopback and validates Host, Origin, JSON content type, and a per-session token. It is a local application, not an internet-facing service.

---

## About this project

Caret is a local, keyboard-first implementation of the **M1 core loop** from [SKILLROUTER_v3.md](SKILLROUTER_v3.md): ghost text while you type, a calibrated action chip when intent is clear, Tab to accept, and a strict permission gate before anything runs. The original PDF is preserved. The Markdown conversion includes all 24 numbered sections, reconstructed tables, code samples, and an architecture diagram.

The concept, inline completion plus a nearby action, both accepted from the keyboard, with a typed judge deciding when to offer an action, is derived from [theodorexli/Caret](https://github.com/theodorexli/Caret) (MIT). This is a clean-room reimplementation in Node with a different architecture; no code is shared. See [docs/implementation.md](docs/implementation.md) for decisions and [docs/host.md](docs/host.md) for the native macOS host.

The Node helper owns routing, thresholds, the permission gate, the executor, logs, and eval. Hosts are thin clients of its loopback HTTP API. Two hosts exist: the Swift menu-bar app in [apps/mac](apps/mac/README.md), which works at the caret in any application, and a browser page used for development.

### Browser dev host

```sh
npm start
```

Open http://127.0.0.1:4317. Same helper, same controls, but context is pasted by hand and calendar events are local JSON records under `.skillrouter/output/calendar/`. Use it for development and for the eval loop.

### Skills and data

- `skills/<slug>/SKILL.md`: nine bundled skills. Override `metadata.active` with the string `"false"` to disable a skill, then restart. `metadata.label` is the name shown on the chip. A skill that fails validation is skipped and reported at startup and in the UI; it does not stop the helper.
- `.skillrouter/events.jsonl`: local redacted routing states, interaction events, and execution events. Rotated at 5 MB.
- `.skillrouter/registries/`: full registry snapshots keyed by hash for historical reconstruction.
- `.skillrouter/registry-history.jsonl`: every registry version, for rollback.
- `.skillrouter/output/files/`: new local text files.
- `.skillrouter/output/calendar/`: local event JSON records (browser host only).

No telemetry sync or upload is implemented. Local logs contain redacted content, not just counters; treat them as personal data. A session and its undo handles end when the helper restarts. Existing outputs remain on disk.

### Verify and evaluate

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

To grow the labeled set from your own use:

1. `npm run label` walks the distinct sentences in `.skillrouter/events.jsonl` that are not yet in the dataset, proposes the accepted or offered skill, and appends each state with its recorded probabilities.
2. `npm run eval` then replays those states offline. States recorded under an older registry are skipped (`stale_skipped`) until `--live` re-evaluates them; any registry, model, or description change needs `--live` for fresh probabilities.
3. Hand-checked JSONL entries with `state`, `label` (a skill slug or `NO_ROUTE`), and `language` can be added directly.

The report includes a confusion matrix, false and missed-route rates, abstention calibration bins, and per-language counts. Grow this set toward the spec's 300+ real states.

### Implementation boundary

This is an M1 core plus the first M2 pieces, and a usable local prototype. It does **not** implement the PDF's catalog adoption, script sandbox, multi-device sync, or voice input. Active registries over 254 skills fail explicitly rather than silently dropping options. See [implementation notes](docs/implementation.md) for API corrections and remaining validation.

### Done and next

- Done: native macOS host; unknown-intent proposal (⌘⇧N, saved as *reviewed*, hot-reloaded); debug view with per-sentence probabilities; registry history and rollback.
- Done: live models measured (Jev 22/22 on the seed set plus real labeled states; local ghost text 50 to 250 ms warm; executor on Haiku 4.5); lookups for Contacts, GitHub, calendar and mail; hosted executor with local fallback.
- Next: grow the labeled eval set from real use (`npm run label`) and tune thresholds from it; notarization for sharing the app.
- Later: other hosts sharing the same helper. Windows (UI Automation), Linux (AT-SPI), phone (keyboard extension or share target).
