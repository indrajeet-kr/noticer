# Contributing

All code in this repo is written during the hackathon. Do not copy in an older project or a DAT sample. If a later change must quote a snippet, name the source and the license in the README.

No secrets. Do not commit `META_API_KEY`, a keychain dump, or a `.env`. The live client reads that variable from the environment, or the app will keep it in settings. Tests pass a fake key or none.

## Who owns which folder

Edit your track's folder. Leave the other tracks' folders alone so the three branches merge.

| Track | Write here | Do not take |
| --- | --- | --- |
| Core logic | `Sources/NoticerCore/Engine/` and new tests in `Tests/NoticerCoreTests/` | HTTP, tool JSON, DAT, Vision, speech, SwiftUI |
| Agent layer | `Sources/NoticerAgent/` (new files), `fixtures/model-responses/`, new tests in `Tests/NoticerAgentTests/` | Mastery math, the visitor count, DAT, speech |
| iOS app | `ios/`, `fixtures/clips/` | The need engine and the chat-completions parser |
| Integration | `Sources/NoticerPipeline/`, `fixtures/scenarios/`, `Tests/NoticerPipelineTests/`, and the glue that calls them from `ios/` | Rewriting `NeedEngine` or the chat-completions client. Call them. |

`NoticerCore` is the shared contract. `NoticerAgent` depends on it. `NoticerPipeline` depends on both and is the session glue. The app depends on all three products in `ios/project.yml`.

## Contract files

Change these only when the contract itself is the change, and say so in the PR. Other tracks are coding against them.

- `Sources/NoticerCore/` except `Engine/`
- `Sources/NoticerAgent/ToolCatalog.swift`
- `Sources/NoticerAgent/MuseSparkModelClient.swift` (endpoint and call-shape constants)
- `fixtures/model-responses/` envelope shape (`RecordedModelFixture`)

Add new types in your own folder instead of widening a shared file for a local need. The Step 0 tests lock the PRD numbers, the five tool names, and `finish_reason` routing. Add tests in a new file rather than loosening those.

## What Step 0 deliberately does not do

- No glance latch, mastery update, `caught_himself` confirmation, stale-need close, or visitor pause.
- No HTTP in Step 0. `MuseSparkModelClient(apiKey:)` with no transport still throws `notImplemented` after it sees a key, and the Step 0 test locks that. `live(apiKey:)` and `fromEnvironment()` perform chat completions. That HTTP client, the cap gate, the recorder, and `ReplayModelClient` live in `Sources/NoticerAgent/`.
- `ModelBackend.baseten` throws `backendOutOfScope`. Do not add a Baseten request in passing.
- No DAT import, no Vision request, no `AVSpeechSynthesizer`.
- `MasteryState.phase` only classifies the stored score and self-notice streak. Two misses do not un-retire on their own.

## Contract ambiguities

These are open. Do not pick a private answer in one track.

1. **Which assessment fields each tool requires.** The PRD lists one field set inside "the tool arguments" and also gives each tool a different job. Every schema includes all seven fields. Required subsets are narrower (`extension_reason` only on `request_head_start_extension`). `strict: true` is set. It is unconfirmed whether Meta's strict mode also demands that every property be required.

2. **Where `resolved_by_partner` is reported.** None of the five tools is "the partner handled it." `resolution` is an assessment field on every tool, including `report_no_transition`, so a turn can carry it. Whether that is the right tool is undecided. `log_wearer_intervention` is only his action.

3. **`resolution` strings.** The PRD names `resolved_by_partner` and `unknown`, and describes "caught himself" in prose. The JSON values used here are `caught_himself`, `resolved_by_partner`, and `unknown`. Unknown strings decode and are kept. Dropping them is core-track validator work, and it is not implemented.

4. **`action_code` is not a closed set.** The PRD names `wearer_hands_receiving_baby`, `wearer_carrying_water_toward_partner`, and the passive counterexample `water_glass_present`. Do not invent the rest of the enum separately in each track.

5. **`partner_state_evidence`.** Encoded as an array of strings. There is no vocabulary.

6. **Head-start extension step.** Agreed value is 15 seconds, `EngineTuning.headStartExtensionStepSeconds`. The engine grants that step. The session pipeline passes the same number into `HardCapGate(extensionStepSeconds:)`. Do not pick a second step size.

7. **Per-need dwell versus H₀.** `Need.dwellSeconds` is the compile step's dwell. The fade spec also has H₀ = 90 seconds and `H = H₀ · (1 + 2·m)` capped at 120. Which one wins is undecided. Nothing reads `dwellSeconds`.

8. **`finish_reason: length`.** It is an error (`ModelContractError.truncated`), not a no-op. `stop` becomes `report_no_transition` and still keeps any assessment payload, with `extension_reason` cleared. The engine must branch on the tool name. `tool_calls` may arrive with a non-null `content` string. The tool wins. The string is not a verdict.

9. **More than one tool call.** The type holds one verdict because `parallel_tool_calls` is false. A multi-call body has no contract.

10. **Check-in wording.** `CueKind.checkIn` and `Need.allowsCheckIn` exist. The phrase to speak is not specified.

11. **Visitor measurements.** `FrameGateSnapshot` is normalized rects plus a wearer-hands flag. Adult versus baby thresholds are not set. Person rects include a baby or a screen until a later rule says otherwise. The same-chore exception to the 45 second close has no type yet.

12. **Keyframe bytes.** `Keyframe` holds JPEG bytes and `ageSeconds` (Δt behind the newest frame). It does not store a file path. Decoding `fixtures/clips` is iOS work. The core replay stub only yields frames it was given.

13. **MWDAT Info.plist.** The nested `MWDAT` / `Analytics` / `OptOut` and `CrashReporting` / `OptOut` keys follow the PRD wording. Confirm them against the SDK README before linking it.

14. **iOS version.** The XcodeGen spec targets iOS 18 so `Synchronization.Mutex` is available. The PRD does not name a version. Low versus medium DAT resolution, and a 512 px upload size, are also unset.

15. **Replay file shape.** Cached responses are the normalized envelope in `fixtures/README.md`, plus an empty `raw_completion` for the real HTTP body. Confidence in the sample latch file is not a gate.

16. **API key storage on device.** The environment variable is the contract. Keychain versus another store is not chosen.

17. **Same list on the model request.** `ModelRequest.needs` might be every authored need or only the open ones. The stub does not filter.

## Tests

```sh
swift test
```

That is what CI runs on Linux. The iPhone app is not part of that job.
