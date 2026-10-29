# Noticer on a Mac

This is the iPhone app. Linux CI runs `swift test` for the shared packages and does not compile `ios/`. Build and run it in Xcode on your Mac.

The glasses SDK is Meta Wearables Device Access Toolkit **1.0.1**, pinned in `ios/project.yml`. That tag is the 1.0 line that still contains `Package.swift`.

- Package: <https://github.com/facebook/meta-wearables-dat-ios>
- Tag: <https://github.com/facebook/meta-wearables-dat-ios/tree/1.0.1>
- Manifest: <https://github.com/facebook/meta-wearables-dat-ios/blob/1.0.1/Package.swift>

Products linked into the app: `MWDATCore` and `MWDATCamera`. The app does not link Mock Device Kit, speech, or the microphone.

## 1. Xcode

Meta's current getting-started page asks for **Xcode 26.4 or later** and **iOS 17.2+**. The 1.0.1 binary was built with Swift 6.3.3 and targets iOS 17.2.

- <https://wearables.developer.meta.com/docs/develop/dat/>
- <https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/getting-started/SKILL.md>

Install Xcode from the Mac App Store, open it once, and let it install the extra components. The app target's Swift language mode stays 6, matching `Package.swift`.

## 2. Generate the project

Install [XcodeGen](https://github.com/yonaskolb/XcodeGen), then generate. Do not commit the generated project.

```sh
brew install xcodegen
cd ios
xcodegen generate
open Noticer.xcodeproj
```

Run that again after you pull. Clips and recorded model responses are folder references to `fixtures/clips` and `fixtures/model-responses`. Put a clip in `fixtures/clips` before you build. `mp4`, `mov`, and `m4v` are the extensions the player looks for.

`INFOPLIST_PREPROCESS` is off so the callback scheme keeps its `://`. Meta documents that the C preprocessor would strip it: [TN2175](https://developer.apple.com/library/archive/technotes/tn2175/_index.html#//apple_ref/doc/uid/DTS10004415-CH1-TNTAG3).

## 3. Sign with a free Apple ID

1. In Xcode, open **Settings → Accounts**, click **+**, and sign in with your Apple ID. A Personal Team appears. You do not need a paid Developer Program membership for a device you own.
2. Select the **Noticer** target, then **Signing & Capabilities**.
3. Check **Automatically manage signing**.
4. Set **Team** to your Personal Team. Xcode writes `DEVELOPMENT_TEAM`. `Info.plist` fills `MWDAT → TeamID` from that setting.
5. If Xcode says the bundle id `app.noticer.Noticer` is unavailable, change `PRODUCT_BUNDLE_IDENTIFIER` in `ios/project.yml`, run `xcodegen generate` again, and leave the URL scheme as `noticer` unless you also change it in both places below.

Connect the iPhone with a cable, tap **Trust**, and choose that iPhone as the run destination. Press **Run**.

On the phone, if iOS asks, trust the developer certificate: **Settings → General → VPN & Device Management**.

A free Personal Team usually cannot add the **Hotspot Configuration** capability (`com.apple.developer.networking.HotspotConfiguration`). This project does not include that entitlement, so signing can succeed. Meta's integration page says Wi-Fi camera streaming needs it, because the phone joins a network the glasses host. See the transport note below.

Signing help: <https://developer.apple.com/help/account/access/sign-in-to-your-developer-account/>

## 4. Developer Mode on the iPhone

iOS will not launch a development app until Developer Mode is on.

1. After the first install attempt, open **Settings → Privacy & Security → Developer Mode**.
2. Turn it on and restart the phone.
3. Confirm the prompt after restart.

Apple's steps: <https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device>

## 5. Meta AI app and glasses versions

DAT **1.0.1** lists Meta AI **V292** and glasses firmware **V128**. Use those or newer.

- Version table: <https://wearables.developer.meta.com/docs/develop/dat/version-dependencies/>
- Meta AI on the App Store: <https://apps.apple.com/us/app/meta-ai-assistant-glasses/id1558240027>

Check the phone app version under **Settings → App Info**. Check the glasses under the **Devices** tab, then the gear, **General → About → Version**. Update both from the Meta AI app if they are older.

## 6. Developer mode, then the toolkit on the glasses

Meta's setup page, not a separate undocumented toggle:

1. In the Meta AI app, open **Settings → App Info**.
2. Tap the **App version** number **five times**.
3. Turn **Developer Mode** on and confirm.
4. Put the glasses on. Meta's display setup says this is required before the install.
5. If Developer Mode is already on, press the **install** button to install the Device Access Toolkit onto the glasses.
6. On iOS, accept the Wi-Fi prompt if it appears. Keep the Meta AI app open until the install finishes (Meta says about 5–10 seconds).

The same steps are on:

- <https://wearables.developer.meta.com/docs/develop/dat/getting-started-toolkit/>
- <https://wearables.developer.meta.com/docs/develop/dat/display-overview/>

In Developer Mode only one third-party app stays registered. Registering Noticer drops another developer app.

- <https://wearables.developer.meta.com/docs/develop/dat/permissions-requests/>

## 7. Register the app with Meta

1. Create an account and a project at <https://wearables.developer.meta.com/>.
2. Open the project, then **Configuration**, and add the iOS app. The page tells you to copy the integration details into the build.
3. **Manage projects:** <https://wearables.developer.meta.com/docs/develop/dat/manage-projects/>

For Developer Mode the app ships `MetaAppID` and `ClientToken` as `0`. Meta's iOS getting-started skill says a Developer Mode `MetaAppID` may be empty, `0`, or an unexpanded `$(META_APP_ID)` placeholder. The Android integration page says Developer Mode may omit the ids or use `0`.

When you leave Developer Mode, replace both strings in `ios/Noticer/Info.plist` with the Application ID and client token from the project configuration, regenerate if you change the file from Xcode, and rebuild.

In the Noticer app, tap **Register with Meta AI**. The Meta AI app opens for approval and calls back through the URL scheme. The screen should move to **Registered**. Then start a **Live** session so Noticer can ask for the glasses **camera** permission. It never asks for the microphone.

## 8. URL scheme and Info.plist

The scheme is `noticer`. These two values match on purpose:

- `CFBundleURLTypes → CFBundleURLSchemes → noticer`
- `MWDAT → AppLinkURLScheme → noticer://`

The app only forwards a callback to the SDK when the URL has a `metaWearablesAction` query item, which is what Meta's registration skill does.

`MWDAT → Analytics → OptOut` and `MWDAT → CrashReporting → OptOut` are `true`. That matches the SDK README: missing or false means collection stays on.

- <https://github.com/facebook/meta-wearables-dat-ios/blob/1.0.1/README.md>

Other keys, and where they come from:

| Key | Why it is here |
| --- | --- |
| `NSBluetoothAlwaysUsageDescription`, `UIBackgroundModes` `bluetooth-central` | Required for Bluetooth LE in the iOS integration guide. |
| `bluetooth-peripheral`, `NSBluetoothPeripheralUsageDescription` | Present in the CameraAccess sample and the GitHub getting-started skill. |
| `external-accessory`, `UISupportedExternalAccessoryProtocols` `com.meta.ar.wearable` | The getting-started skill says Bluetooth Classic camera streaming checks these. The integration page also says the SDK uses External Accessory. |
| `audio` | A whisper can finish through the glasses speaker if the phone is locked or in a pocket. This is playback, not the glasses microphone. |
| `NSLocalNetworkUsageDescription`, `NSBonjourServices` `_bonjour._tcp` | Wi-Fi streaming in the integration guide. |
| `NSCameraUsageDescription` | The integration guide includes a camera usage string. Noticer does not use the iPhone camera as the session camera. |

There is **no** `NSMicrophoneUsageDescription`. `UIBackgroundModes` does include `audio`, alongside `bluetooth-central`, `bluetooth-peripheral`, and `external-accessory`, so `AVSpeechSynthesizer` can finish a whisper while the phone is locked. The sample app adds `audio` because it records the glasses microphone. Noticer does not record. The camera stream can still pause when the app leaves the foreground; `audio` does not keep that stream alive.

Sources:

- Integration guide: <https://wearables.developer.meta.com/docs/develop/dat/build-integration-ios/>
- Getting-started skill: <https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/getting-started/SKILL.md>
- CameraAccess sample plist (do not copy the sample into this repo): <https://github.com/facebook/meta-wearables-dat-ios/blob/main/samples/CameraAccess/CameraAccess/Info.plist>

The integration guide's plist example and the GitHub skill do not list the same transport keys. The choice is marked `TODO(verify)` in `Info.plist`. Hotspot Configuration is documented for Wi-Fi streaming and is omitted here so a free Personal Team can sign.

Streaming reference: <https://wearables.developer.meta.com/docs/develop/dat/streaming/>

## 9. What the phone does

The screen is dark and stays awake only while a session is running and the app is in front. `isIdleTimerDisabled` is set for that case. If you leave the app, live frames are dropped and the status says to bring it back. Pocket mode is not supported.

**Mom's list.** Up to six needs: id, her words, the cue, priority, and whether a check-in is allowed. The list is saved on the phone. The default ids are `take-baby` and `refill-water`, the same pair the engine and the scenario fixtures use. The check-in phrase itself is not specified, so the app only stores the toggle.

**Live / Replay.** Live opens the glasses camera at 2 fps, `.raw`, `.low`, with no audio codec. Replay can play a bundled scenario from `fixtures/scenarios` with no clip and no API key. The scenario clock jumps, so the head start does not take 90 wall-clock seconds. A clip, when you add one, is read with `AVAssetImageGenerator` at 2 fps and played through `ReplayFrameSource`. Recorded model turns for a clip come from `fixtures/model-responses`. A truncated fixture is skipped because that file is an error sample.

**API key.** Save it with **Save to Keychain**. It is a generic password in the Keychain, not in the repo and not in logs. A saved key is used before `META_API_KEY` in the process environment. Replay does not need a key. Live mode, with a key, calls Muse Spark. With no key it does not open a connection.

**Pipeline.** Each frame is turned into a JPEG of about 512 px on the long side at quality 0.65, held in memory, and run through the signal gate: downsampled luma motion (mean absolute difference) and sharpness (Laplacian variance). That gate admits keyframes. It does not detect people or hands. When nothing is open it samples slowly (about every 20 seconds, plus a motion jump). When a need is open it admits changes about every 4 seconds, and the engine still heartbeats every 8 seconds. One Muse Spark call is in flight at a time; the next tick waits until that call returns or hits the 20 second in-flight limit. Spark's tool arguments include `partner_in_view`, `wearer_hands_visible`, and `wearer_hands_occupied`. `SessionPipeline` hands the verdict to `NeedEngine` for the head start, mastery, and the cue. A scenario uses the scripted signal gate and needs no API key, because the fixture already says who is in frame. The head-start extension step is 15 seconds, passed into `HardCapGate`. Head start, mastery, and the caps are unchanged.

**Cues.** `GlassesCueSpeaker` uses `AVSpeechSynthesizer` on a `.playback` / `.spokenAudio` / `.duckOthers` session. **Dismiss cue** stops speech. The glasses microphone is never opened.

**Glasses.** Any `DeviceType` is accepted, including `rayBanMetaOptics`. The app does not require `rayBanMeta`. `CAPABILITY_DENIED` is surfaced once. A stopped stream is replaced with `addCamera`. `start()` is not called again on that stopped stream. A stopped device session is not restarted in place.

Gen 3 notes from Meta staff: <https://github.com/facebook/meta-wearables-dat-ios/discussions/323>

## 10. Checks that still need the phone

Search the iOS sources for `TODO(verify)`. They are the spots this machine could not compile or run: the iOS error enum versus `CAPABILITY_DENIED`, transport keys, Hotspot, low versus medium resolution, `makeUIImage()` on a raw frame, the fresh-camera restart on hardware, and whether playback stays on A2DP without opening HFP. JPEG upload size is 512 px at quality 0.65. Partner in view and wearer hands come from Muse Spark, not from an on-device detector. `MWDAT > Analytics > OptOut` and `MWDAT > CrashReporting > OptOut` are already `true`. The SDK 1.0.1 README documents those Info.plist keys and no other analytics switch.
