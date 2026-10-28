# Fixtures

`clips/` is where recorded POV clips go. Step 0 does not decode video. Do not commit footage you would not publish, and do not put an API key in a clip name or sidecar.

`model-responses/` holds cached model turns for replay. Each file is a normalized envelope:

- `fixture_id`
- `normalized.finish_reason` (`tool_calls`, `stop`, or `length`)
- `normalized.tool` (a tool name, or null)
- `normalized.assessment` (any subset of the shared assessment fields)
- `normalized.extension_reason` (optional)
- `raw_completion` (null on the hand-written tapes; the recording client stores the HTTP body here)
- `request` (optional; omitted by the original tapes). The recording client writes a fingerprint, keyframe ids, ages, and byte counts. It does not write JPEG bytes. `ReplayModelClient` matches on `request.fingerprint` and returns that verdict every time. Tapes without `request` stay on `RecordedModelClient`, which plays them in order.

`confidence` in a sample is not a threshold. `stop` is routed to `report_no_transition`. `length` is an error, not a verdict.

The iOS replay path and the `swift test` harness should both read these files through `RecordedModelClient` and `FrameSource`. Nothing here calls the network.
