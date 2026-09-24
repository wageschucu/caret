# Implementation decisions and validation

Source specification: `SKILLROUTER_v3.md`, converted from the supplied PDF without changing its original claims. Implementation corrections are recorded here instead.

## API verification — 2026-09-22

- [TypeSafe HTTP API](https://docs.typesafe.ai/api) specifies `answers.ready.noul`, `answers.skill.probabilities`, and a reported model ID. **Correction 2026-09-24:** the documented `https://api.typesafe.ai/v1/systemone` URL answers 401 for a valid key; the working endpoint is `https://jevtypesafeai.com/api/v1/decide` (Bearer auth, same request and response shape, `usage.cost_usd` and `credits_remaining_usd` included). `JEV_ENDPOINT` overrides it. The adapter validates the returned option set, values, and distribution sum. Routing uses probabilities directly, not the additional confidence field.
- [TypeSafe Choice](https://docs.typesafe.ai/primitives/choice) documents an ordinary none-of-the-above option. The [Rust client](https://docs.rs/typesafe-systemone/latest/typesafe_systemone/) calls this a conventional option name. The PDF’s proposed `abstain: true` field is therefore replaced with `none_of_the_above: null` in Choice criteria. It is not a registry skill and consumes one of 255 options.
- [Current models](https://docs.typesafe.ai/models) identifies `jev-1.13.0`; the application pins that ID by default and logs the response’s actual model ID.
- [Agent Skills format](https://agentskills.io/specification) specifies string metadata and space-separated `allowed-tools`. Bundled files comply. The loader also accepts the PDF’s array representation for compatibility.
- Screenpipe was integrated on 2026-09-22 and removed on 2026-09-24 (see below). The `screens` array in state remains; the host supplies it.

## Decisions — 2026-09-24

- **Origin.** The concept derives from [theodorexli/Caret](https://github.com/theodorexli/Caret) (Python + Swift + Screenpipe/Skyvern submodules). This project shares no code with it and is not a fork; it is credited as the design source in the README.
- **Host.** The product must work in any application at the caret. The browser page in `public/` stays as a development host; the real host is a native macOS menu-bar app specified in [host.md](host.md). The Node helper is the portable core and keeps the same HTTP contract.
- **Screenpipe removed.** Its only role was recent-screen text. The macOS Accessibility API gives the focused field, selection, window title, app name, secure-field flag, and (via a small in-memory ring buffer on focus change) recent windows, with no recording and no cost. `SCREENPIPE_*` variables, the `/api/route` fetch, and the UI checkbox are gone. `trimState` still accepts `screens` from the host.
- **Robustness.** A skill that fails validation is skipped and reported (`problems` in `/api/bootstrap`) instead of stopping startup. Sessions older than 24 h are pruned on bootstrap; pending previews expire after 10 min and undo handles are capped at 50. `events.jsonl` rotates at 5 MB. The large-set margin (0.02) is now part of `THRESHOLDS` (`largeSetMargin`) so every threshold is versioned. Windows reserved device names are rejected as filenames.
- **Slot answers are not redacted.** Text the user types into a missing-slot field is their explicit input and may be saved verbatim; redaction previously rewrote e.g. IBAN-like strings inside saved files. Redaction still applies to everything logged and to all screen context.
- **Chip labels** come from `metadata.label` in SKILL.md, not a hardcoded map in the client.
- **Calendar class.** `calendar.create` writes a local JSON record but is classed `sends-or-pays` deliberately: it stands in for a real calendar tool and the confirmation flow should not change when one is connected.

## Delivered M1 components

| Component | Implementation |
| --- | --- |
| Host | Standalone local browser typing field with a Node helper |
| Completer | Streaming compatible-provider adapter; cancellation, punctuation/token/time limits; explicitly labeled demo fallback |
| Router | One Jev request with two questions; 300 ms UI debounce and phrase-boundary trigger |
| State | Deduplication, age/count bounds, host deny/secure exclusion, secret redaction, conservative byte budget |
| Thresholds | Canonical entry bars, hysteresis, Esc suppression, large-set ratio logic |
| Skills | Eight portable seed directories; contrastive criteria derived from frontmatter |
| Permission gate | All four classes; trust filtering; effect floor derived from actual host tool |
| Executor | Skill body + declared context; structured slot/plan generation; exact tool arguments displayed |
| Effects | Text results, exclusive local file creation, local calendar creation, session undo |
| Logs | Redacted states, registry snapshots, model ID, thresholds, distribution, actions, execution events |
| Evaluation | Labeled JSONL replay, live re-evaluation, regression check, confusion and calibration reports |

The standalone host is an implementation choice for the PDF’s open host question. Global input interception and browser-extension permissions are outside this build. The application only intercepts its own typing field and preview. The model adapters are wired but require user-provided credentials/models; demo rules are never reported as Jev results.

## Validation

16 automated tests pass, including HTTP integration with duplicate confirmation and undo. Browser checks verified one-Tab translation, missing-slot calendar preview, a separate final confirmation card, and Esc cancellation. Live TypeSafe and external generation were not exercised because no services/credentials were configured. Measured production latency, multilingual accuracy, and the below-20% missed-route success criterion remain unverified.

## Remaining milestones

M2: opt-in unknown-intent proposal, authoring interface, debug view, registry versioning/rollback, replay-derived per-user thresholds.

M3: catalog embeddings/health/vetting/adoption, reviewed-script sandbox, large-registry prefilter or hierarchical Choice, multi-device sync, and voice transcription.

Before M2: the native macOS host ([host.md](host.md)) and live-model validation.

No code path claims these later milestones are present. Scripts remain blocked, external calendars/email/purchases are not connected, and registries above the live cap return an actionable error. The initial skill bundle is loaded directly from the project to avoid modifying a user-global registry; a future installer can copy it into `~/.skillrouter/skills`.
