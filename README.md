# Noticer

Noticer helps a new dad notice what his partner needs before she has to ask.

Mom writes a short list of everyday needs (take the baby, refill my water). Dad wears Ray-Ban Meta glasses. When the glasses spot one of those needs, he gets a head start to notice on his own, then a whispered cue if he doesn't. As he learns, the cues fade out.

Built for the Meta Global AI Developer Hackathon ("Build for Your World").

## How it works

- The glasses stream camera frames to an iPhone app.
- An on-phone person and hand check (Apple Vision) decides when a frame is worth sending.
- Muse Spark reads keyframes against mom's list and decides whether a need is real.
- The phone speaks a quiet cue, and cues retire once dad keeps catching that need himself.

## Status

Step 0 is the shared skeleton: types, protocols, stubs, Linux tests, and the iOS app shell. The need engine, Vision gate, and glasses session are not implemented. The agent track now calls Muse Spark over chat completions, enforces the hard caps, and can record or replay a turn. All code in this repo was written during the hackathon.

Replay mode (recorded clips plus cached responses, no API key and no glasses) is the path judges will run. `ReplayModelClient` serves `fixtures/model-responses` by request fingerprint and does not read a key. `RecordedModelClient` still plays a fixture list in order.

## Architecture

```
Ray-Ban Meta Gen 3  -- DAT camera, 2 fps, glasses speaker
        |  FrameSource          live seam (SDK not linked) | replay frames
        v
Vision gate             iOS track, not built
        |  FrameGateSnapshot
        v
Need engine             NoticerCore/Engine, not built
        |  Keyframe strip + Need list
        v
ModelClient             Muse Spark chat completions | recorded fixtures | replay | Baseten slot (refused)
        |  ModelVerdict   (one tool + SceneAssessment)
        v
Need engine             timers, caps, mastery, caught_himself, stale need, visitor rule
        |  Cue
        v
CueSpeaker              recording stub | glasses speech seam (no AVSpeech yet)
```

`Clock` is injected so tests move the head-start window without sleeping.

The phone owns timing and the hard caps. A model tool call is a request. Baseten is a second `ModelClient` backend and is out of scope: selecting it throws, and no request is built. Frames stay in memory. The Meta API key comes from the `META_API_KEY` environment variable or, later, the app's settings. It is not in the repo.

Live calls, when they exist, go to `POST https://api.meta.ai/v1/chat/completions` with model `muse-spark-1.3`, `tool_choice: auto`, and `parallel_tool_calls: false`. `reasoning_effort: none` is not a candidate.

## Track boundaries

Three tracks can work in parallel. Folder ownership and the contract files they should not edit are in [CONTRIBUTING.md](CONTRIBUTING.md).

| Track | Owns later | Step 0 leaves them |
| --- | --- | --- |
| Core logic | Need list, glance latch, mastery updates, `caught_himself`, stale need, visitor rule | Types and limits only, in `NoticerCore` |
| Agent layer | Muse Spark chat completions, the 5 tool handlers, hard caps, record and replay | Tool JSON schemas and client stubs, in `NoticerAgent` |
| iOS app | DAT camera ingest, Vision person/hand gate, `AVSpeechSynthesizer` cues, phone UI, replay mode | App shell and seams, in `ios/` |

`NoticerAgent` depends on `NoticerCore`. The iOS app depends on both. Core does not depend on the agent or on Apple frameworks, so `swift test` runs on Linux.

## Repository layout

```
Package.swift
Sources/NoticerCore/          shared types, protocols, stubs
Sources/NoticerCore/Engine/   empty; core track adds the engine here
Sources/NoticerAgent/         five tool schemas, model client stubs
Tests/                        contract tests
ios/project.yml               XcodeGen spec for the iPhone app
ios/Noticer/                  SwiftUI shell and DAT / speech seams
fixtures/clips/               POV clips (none yet)
fixtures/model-responses/     cached model turns
.github/workflows/swift-test.yml
```

Generate the Xcode project on a Mac with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
cd ios && xcodegen generate
```

The DAT SDK is not a package dependency. `DATCameraSeam` and `UnlinkedDATFrameSource` are the seam. Do not import it until the iOS track is ready.

## Shared contracts

Types: `Need`, `Keyframe`, `CameraFrame`, `FrameGateSnapshot`, `ModelVerdict`, `SceneAssessment`, `Cue`, `MasteryState`.

Protocols: `FrameSource`, `ModelClient`, `CueSpeaker`, `Clock`.

Tools: `latch_need_hypothesis`, `defer_cue_wearer_busy`, `log_wearer_intervention`, `request_head_start_extension`, `report_no_transition`.

`ModelTurnNormalizer` maps `finish_reason: stop` to `report_no_transition` and rejects `length`. It does not validate need ids or action codes.

## Gate G0

One live check from a Mac. It does not run in CI, and it does not call Baseten.

```sh
export META_API_KEY=...   # never commit this
swift run noticer-gate-g0
swift run noticer-gate-g0 --reasoning-effort minimal --repeats 20
```

Pass means every call came back with `finish_reason: tool_calls`. The command prints the endpoint, reasoning effort, max tokens, latency, usage, and an estimated cost read from `usage`. `stop` is a reachable model that did not call a tool (exit 2). `none` is rejected locally because the API returns HTTP 400. A value of `max_tokens` under 1024 is rejected for the same reason: reasoning tokens count toward that cap.

Flags and environment variables are listed by `swift run noticer-gate-g0 --help`.

| Knob | Default |
| --- | --- |
| Endpoint | `https://api.meta.ai/v1` (a full `.../chat/completions` URL also works) |
| Model | `muse-spark-1.3` |
| `reasoning_effort` | `low` (`minimal`, `medium`, `high`, `xhigh`, `max` are allowed) |
| `max_tokens` | `1024`, or `unset` to omit it |
| Timeout | 60 seconds |
| Retries | 3 attempts, backoff from 0.5s, capped at 8s. 429 and 5xx retry. 400 and `model_not_found` do not |
| Call budget | 300 per `live()` / `fromEnvironment()` client |
| Extension step | none until the caller passes one. The 120s cap is still enforced |
| API key | `META_API_KEY` or the initializer. Not stored in the repo |

`--record fixtures/model-responses` writes the pair for replay. The file stores the response and a request fingerprint, not the JPEG bytes.

## Build and test

```sh
swift test
```

CI runs that on Ubuntu for every pull request. The iOS target is not built in CI. Tests use a fake HTTP transport and do not call Meta.

## Privacy

Sampled frames will go to Meta's API in live mode, or to Baseten if that fallback is added later. This repo does not send them. Rules, labels, and the log are what stay on the phone. Frames are not written to disk by these types. Retention terms for the APIs were not checked. There is no microphone permission: the glasses mic stays closed.

## License

MIT
