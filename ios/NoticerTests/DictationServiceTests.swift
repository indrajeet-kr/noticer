import Foundation
import XCTest

@MainActor
final class FakeSpeechTranscriber: SpeechTranscribing {
    var permissionGranted = true
    var partials: [String] = []
    var startCount = 0
    var stopCount = 0

    func requestPermissions() async -> Bool {
        permissionGranted
    }

    func start(onPartial: @escaping @Sendable (String, Bool) -> Void) throws {
        startCount += 1
        for partial in partials {
            onPartial(partial, false)
        }
    }

    func stop() {
        stopCount += 1
    }
}

/// Dictation: partials fill the transcript, recording is off during a
/// session, and denied permissions get a calm notice instead of a crash.
final class DictationServiceTests: XCTestCase {
    func testPartialsFillTheTranscript() async {
        let fake = await MainActor.run { FakeSpeechTranscriber() }
        await MainActor.run { fake.partials = ["hello", "hello there"] }
        let service = await MainActor.run { DictationService(transcriber: fake) }

        let handled = await service.toggle()
        XCTAssertTrue(handled)
        // Partials arrive on a MainActor hop after toggle returns.
        var transcript = ""
        for _ in 0..<100 {
            transcript = await MainActor.run { service.transcript }
            if transcript == "hello there" {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(transcript, "hello there")
        let recording = await MainActor.run { service.isRecording }
        XCTAssertTrue(recording)

        _ = await service.toggle()
        let stopped = await MainActor.run { service.isRecording }
        XCTAssertFalse(stopped)
        let stops = await MainActor.run { fake.stopCount }
        XCTAssertEqual(stops, 1)
    }

    func testDisabledWhileSessionRunning() async {
        let fake = await MainActor.run { FakeSpeechTranscriber() }
        let service = await MainActor.run {
            let service = DictationService(transcriber: fake)
            service.sessionRunning = true
            return service
        }

        let handled = await service.toggle()

        XCTAssertFalse(handled, "the mic must fall back to the keyboard during a session")
        let starts = await MainActor.run { fake.startCount }
        XCTAssertEqual(starts, 0, "no record session may open while Noticer is running")
        let notice = await MainActor.run { service.notice }
        XCTAssertEqual(notice, "Voice typing is off during a session")
    }

    /// The OS answers authorization requests on a background queue. A
    /// MainActor-isolated resume closure traps there (EXC_BREAKPOINT, seen
    /// twice on device); these fire the callbacks off-main like TCC does.
    func testSpeechAuthorizationSurvivesBackgroundCallback() async {
        let granted = await LiveSpeechTranscriber.speechAuthorization { handler in
            DispatchQueue.global(qos: .default).async {
                handler(.authorized)
            }
        }
        XCTAssertTrue(granted)
        let denied = await LiveSpeechTranscriber.speechAuthorization { handler in
            DispatchQueue.global(qos: .default).async {
                handler(.denied)
            }
        }
        XCTAssertFalse(denied)
    }

    func testMicrophoneAuthorizationSurvivesBackgroundCallback() async {
        let granted = await LiveSpeechTranscriber.microphoneAuthorization { handler in
            DispatchQueue.global(qos: .default).async {
                handler(true)
            }
        }
        XCTAssertTrue(granted)
    }

    func testDeniedPermissionsShowNotice() async {
        let fake = await MainActor.run {
            let fake = FakeSpeechTranscriber()
            fake.permissionGranted = false
            return fake
        }
        let service = await MainActor.run { DictationService(transcriber: fake) }

        let handled = await service.toggle()

        XCTAssertFalse(handled)
        let starts = await MainActor.run { fake.startCount }
        XCTAssertEqual(starts, 0)
        let recording = await MainActor.run { service.isRecording }
        XCTAssertFalse(recording)
        let notice = await MainActor.run { service.notice }
        XCTAssertTrue(notice?.contains("microphone") ?? false)
    }
}
