import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import MWDATCamera
import MWDATCore
import NoticerCore
import UIKit

/// What the phone screen shows about the glasses. Device type is the SDK's raw
/// value. Gen 3 may report `rayBanMetaOptics`; this type never requires `rayBanMeta`.
struct DATLiveStatus: Sendable, Equatable {
    var deviceType: String = "—"
    var battery: String = "—"
    var thermal: String = "—"
    var hinge: String = "—"
    var stream: String = "Idle"
    var needsResume: Bool = false
    var notices: [String] = []
}

enum DATSourceError: LocalizedError, Sendable {
    case cameraPermissionDenied
    case sessionStopped
    case timedOut
    case notReady
    case capabilityDenied
    case message(String)

    var errorDescription: String? {
        switch self {
        case .cameraPermissionDenied:
            return "Camera permission was not granted in the Meta AI app."
        case .sessionStopped:
            return "The glasses session stopped."
        case .timedOut:
            return "The glasses did not start a session. Check that they are on, registered, and nearby."
        case .notReady:
            return "The glasses were not ready for a camera."
        case .capabilityDenied:
            return "The glasses denied the camera (CAPABILITY_DENIED)."
        case .message(let text):
            return text
        }
    }
}

/// Glasses camera as a pull `FrameSource`.
///
/// A stopped stream is replaced with `DeviceSession.addCamera`. `Stream.start()`
/// is called only on that new stream. A stopped `DeviceSession` is terminal in
/// DAT 1.0, so the next session is a new `createSession`, not `start()` on the old one.
///
/// TODO(verify): Meta staff described the fresh-`addCamera` restart as untested on
/// hardware (github.com/facebook/meta-wearables-dat-ios/discussions/323).
final class DATFrameSource: FrameSource, Sendable {
    private let engine = DATEngine()

    func setStatusHandler(_ handler: @escaping @Sendable (DATLiveStatus) -> Void) async {
        await engine.setStatusHandler(handler)
    }

    func start() async throws {
        try await engine.start()
    }

    func stop() async {
        await engine.stop()
    }

    func setForeground(_ foreground: Bool) async {
        await engine.setForeground(foreground)
    }

    func resume() async throws {
        try await engine.resume()
    }

    func nextFrame() async throws -> CameraFrame? {
        try await engine.nextFrame()
    }
}

/// TODO(verify): iOS DAT 1.0 `DeviceSessionError` has no `CAPABILITY_DENIED` case.
/// The version-dependencies page names that case, and Android 1.0 has it.
/// https://wearables.developer.meta.com/docs/reference/ios_swift/dat/1.0/mwdatcore_devicesessionerror
/// https://wearables.developer.meta.com/docs/develop/dat/version-dependencies/
private enum DATCapability {
    static func isDenied(_ error: DeviceSessionError) -> Bool {
        if case .unexpectedError(let description) = error, containsToken(description) {
            return true
        }
        return containsToken(error.description) || containsToken(error.localizedDescription)
    }

    private static func containsToken(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("CAPABILITY_DENIED")
            || text.localizedCaseInsensitiveContains("capabilityDenied")
    }
}

private actor DATEngine {
    private var status = DATLiveStatus()
    private var onStatus: (@Sendable (DATLiveStatus) -> Void)?
    private var session: DeviceSession?
    private var camera: Camera?
    private var tokens: [any AnyListenerToken] = []
    private var errorTask: Task<Void, Never>?
    private var streamState: StreamState?
    private var running = false
    private var foreground = true
    private var suspended = false
    private var attaching = false
    private var armedForStop = false
    private var acceptingFrames = false
    private var cameraGeneration = 0
    private var finished = false
    private var failure: DATSourceError?
    private var buffer: [CameraFrame] = []
    private var waiter: CheckedContinuation<CameraFrame?, Never>?

    func setStatusHandler(_ handler: @escaping @Sendable (DATLiveStatus) -> Void) {
        onStatus = handler
        handler(status)
    }

    func start() async throws {
        failure = nil
        finished = false
        running = true
        suspended = false
        acceptingFrames = foreground
        do {
            try await openSessionIfNeeded()
            try attachFreshCamera(allowNewSession: true)
        } catch {
            let wrapped = Self.wrap(error)
            running = false
            acceptingFrames = false
            errorTask?.cancel()
            failure = wrapped
            publish()
            throw wrapped
        }
    }

    func resume() async throws {
        suspended = false
        running = true
        acceptingFrames = foreground
        status.needsResume = false
        failure = nil
        do {
            try await openSessionIfNeeded()
            try attachFreshCamera(allowNewSession: true)
        } catch {
            let wrapped = Self.wrap(error)
            errorTask?.cancel()
            failure = wrapped
            publish()
            throw wrapped
        }
    }

    func stop() {
        running = false
        acceptingFrames = false
        suspended = false
        camera?.stop()
        session?.stop()
        session = nil
        camera = nil
        streamState = nil
        cancelTokens()
        errorTask?.cancel()
        errorTask = nil
        status.stream = "Stopped"
        status.needsResume = false
        publish()
        finishWaiters()
    }

    func setForeground(_ isForeground: Bool) {
        foreground = isForeground
        acceptingFrames = isForeground && running && !suspended
        if isForeground && running && !suspended {
            let stopped = streamState == .stopped || camera == nil
            if stopped, session?.state == .started {
                try? attachFreshCamera(allowNewSession: false)
            }
        }
        publish()
    }

    func nextFrame() async throws -> CameraFrame? {
        if let failure {
            throw failure
        }
        if !buffer.isEmpty {
            return buffer.removeFirst()
        }
        if finished {
            return nil
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func yield(_ frame: CameraFrame) {
        guard acceptingFrames, running, !finished else {
            return
        }
        // One queued frame. A slow model call must not accumulate JPEGs.
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: frame)
        } else if buffer.isEmpty {
            buffer.append(frame)
        } else {
            buffer[0] = frame
        }
    }

    private func openSessionIfNeeded() async throws {
        if let session {
            switch session.state {
            case .started:
                refreshDevice(session)
                return
            case .starting, .paused:
                try await waitForTransition(session.stateStream())
                refreshDevice(session)
                return
            case .idle:
                let states = session.stateStream()
                try session.start()
                if session.state != .started {
                    try await waitForTransition(states)
                }
                refreshDevice(session)
                return
            case .stopping, .stopped:
                break
            }
        }
        let wearables = Wearables.shared
        let permission = try await wearables.checkPermissionStatus(.camera)
        if permission != .granted {
            let granted = try await wearables.requestPermission(.camera)
            guard granted == .granted else {
                throw DATSourceError.cameraPermissionDenied
            }
        }
        // No device filter. `.rayBanMetaOptics` must be eligible.
        let selector = AutoDeviceSelector(wearables: wearables)
        let created = try wearables.createSession(deviceSelector: selector)
        session = created
        errorTask?.cancel()
        errorTask = Task {
            for await error in created.errorStream() {
                self.noteSessionError(error)
            }
        }
        let states = created.stateStream()
        try created.start()
        if created.state != .started {
            try await waitForTransition(states)
        }
        refreshDevice(created)
    }

    private func waitForTransition(_ states: AsyncStream<DeviceSessionState>) async throws {
        let result = await withTaskGroup(of: StartRace?.self) { group in
            group.addTask {
                for await state in states {
                    if state == .started {
                        return .started
                    }
                    if state == .stopped {
                        return .stopped
                    }
                }
                return .stopped
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(20))
                    return .timedOut
                } catch {
                    return nil
                }
            }
            for await value in group {
                if let value {
                    group.cancelAll()
                    return value
                }
            }
            return .stopped
        }
        switch result {
        case .started:
            return
        case .stopped:
            throw DATSourceError.sessionStopped
        case .timedOut:
            throw DATSourceError.timedOut
        }
    }

    /// `Stream.start()` runs only on the camera just returned by `addCamera`.
    private func attachFreshCamera(allowNewSession: Bool) throws {
        guard !attaching else {
            return
        }
        guard let session else {
            throw DATSourceError.notReady
        }
        if session.state == .stopped || session.state == .stopping {
            self.session = nil
            camera = nil
            if allowNewSession {
                throw DATSourceError.sessionStopped
            }
            markNeedsResume()
            return
        }
        attaching = true
        defer { attaching = false }
        cameraGeneration += 1
        let previous = camera
        cancelTokens()
        previous?.stop()
        camera = nil
        armedForStop = false
        let created = try addCamera(to: session, replacing: previous)
        camera = created
        subscribe(to: created)
        created.stream.start()
        status.stream = "Starting"
        status.needsResume = false
        publish()
    }

    private func addCamera(to session: DeviceSession, replacing previous: Camera?) throws -> Camera {
        let config = Self.streamConfiguration()
        do {
            guard let created = try session.addCamera(config: config) else {
                note(DATSourceError.notReady.localizedDescription)
                throw DATSourceError.notReady
            }
            return created
        } catch let error as DeviceSessionError {
            if DATCapability.isDenied(error) {
                suspend(DATSourceError.capabilityDenied.localizedDescription)
                throw DATSourceError.capabilityDenied
            }
            if case .sessionAlreadyStopped = error {
                self.session = nil
                camera = nil
                throw DATSourceError.sessionStopped
            }
            guard case .capabilityAlreadyActive = error else {
                note(Self.message(for: error))
                throw error
            }
            previous?.stop()
            do {
                guard let created = try session.addCamera(config: config) else {
                    note(DATSourceError.notReady.localizedDescription)
                    throw DATSourceError.notReady
                }
                return created
            } catch let retry as DeviceSessionError {
                if DATCapability.isDenied(retry) {
                    suspend(DATSourceError.capabilityDenied.localizedDescription)
                    throw DATSourceError.capabilityDenied
                }
                note(Self.message(for: retry))
                throw retry
            }
        }
    }

    private func subscribe(to camera: Camera) {
        let stream = camera.stream
        let generation = cameraGeneration
        let stateToken = stream.statePublisher.listen { [weak self] state in
            Task { await self?.handleStreamState(state, generation: generation) }
        }
        let frameToken = stream.videoFramePublisher.listen { [weak self] frame in
            let cameraFrame: CameraFrame? = autoreleasepool {
                DATFrames.cameraFrame(from: frame)
            }
            guard let cameraFrame else {
                return
            }
            Task { await self?.yield(cameraFrame) }
        }
        let errorToken = stream.errorPublisher.listen { [weak self] error in
            Task { await self?.handleStreamError(error) }
        }
        tokens.append(contentsOf: [stateToken, frameToken, errorToken])
    }

    private func handleStreamState(_ state: StreamState, generation: Int) {
        guard generation == cameraGeneration else {
            return
        }
        streamState = state
        status.stream = Self.streamLabel(state)
        switch state {
        case .stopped:
            guard armedForStop else {
                publish()
                return
            }
            armedForStop = false
            guard running, foreground, !suspended, session?.state == .started else {
                markNeedsResume()
                return
            }
            // The stopped stream is not started again. A new camera is added.
            try? attachFreshCamera(allowNewSession: false)
        case .stopping:
            publish()
        case .paused, .waitingForDevice, .starting, .streaming:
            armedForStop = true
            publish()
        }
    }

    private func handleStreamError(_ error: StreamError) {
        switch error {
        case .hingesClosed:
            suspend("The glasses hinges are closed. Streaming is paused.")
        case .thermalHot:
            suspend("The glasses are too warm. Streaming is paused.")
        case .batteryLow:
            suspend("The glasses battery is low. Streaming is paused.")
        case .permissionDenied:
            suspend("The glasses camera permission was denied.")
        default:
            note(error.description)
        }
    }

    private func noteSessionError(_ error: DeviceSessionError) {
        if DATCapability.isDenied(error) {
            suspend(DATSourceError.capabilityDenied.localizedDescription)
            return
        }
        note(Self.message(for: error))
    }

    private func suspend(_ message: String) {
        suspended = true
        acceptingFrames = false
        note(message)
        markNeedsResume()
    }

    private func markNeedsResume() {
        status.needsResume = running
        if status.stream == "Idle" || status.stream == "Starting" {
            status.stream = "Stopped"
        }
        publish()
    }

    private func note(_ message: String) {
        guard !status.notices.contains(message) else {
            return
        }
        status.notices.append(message)
        publish()
    }

    private func refreshDevice(_ session: DeviceSession) {
        guard let device = session.device else {
            return
        }
        status.deviceType = device.deviceType().rawValue
        if let level = device.batteryLevel {
            status.battery = "\(level)%"
        } else {
            status.battery = "—"
        }
        status.thermal = Self.thermalLabel(device.thermalLevel)
        status.hinge = Self.hingeLabel(device.hingeState)
        publish()
    }

    private func publish() {
        onStatus?(status)
    }

    private func finishWaiters() {
        finished = true
        buffer.removeAll()
        waiter?.resume(returning: nil)
        waiter = nil
    }

    private func cancelTokens() {
        let old = tokens
        tokens = []
        Task {
            for token in old {
                await token.cancel()
            }
        }
    }

    private static func wrap(_ error: Error) -> DATSourceError {
        if let error = error as? DATSourceError {
            return error
        }
        if let error = error as? DeviceSessionError {
            return .message(message(for: error))
        }
        return .message(error.localizedDescription)
    }

    /// No `audioCodec`: camera-stream audio is experimental and this app does not open it.
    /// TODO(verify): `.low` versus `.medium` is still an open contract choice. The MVP line asks for low.
    private static func streamConfiguration() -> StreamConfiguration {
        StreamConfiguration(
            videoCodec: .raw,
            audioCodec: nil,
            resolution: .low,
            frameRate: UInt(SessionLimits.requestedFramesPerSecond)
        )
    }

    private static func message(for error: DeviceSessionError) -> String {
        if DATCapability.isDenied(error) {
            return DATSourceError.capabilityDenied.localizedDescription
        }
        switch error {
        case .noEligibleDevice:
            return "No glasses are connected. Turn them on and connect them in the Meta AI app."
        case .sessionAlreadyExists:
            return "A glasses session is already open."
        case .sessionAlreadyStopped:
            return "The glasses session has stopped. Resume creates a new one."
        case .sessionIdle:
            return "The glasses session has not started yet."
        case .capabilityAlreadyActive:
            return "The camera was already attached."
        case .capabilityNotFound:
            return "The glasses session has no camera to replace."
        case .unexpectedError(let description):
            return description
        case .thermalCritical, .thermalEmergency, .peakPowerShutdown:
            return "The glasses are too hot for a session."
        case .batteryCritical:
            return "The glasses battery is too low for a session."
        case .datAppOnTheGlassesUpdateRequired:
            return "The glasses need a Device Access update in the Meta AI app."
        case .dwaUnavailable:
            return "The glasses companion did not become reachable."
        case .insufficientSDKVersion:
            return "These glasses want a newer Device Access SDK than this build has."
        case .dwaOutOfStuRange:
            return "The app and the glasses are outside the tested version range. The session can still continue."
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func streamLabel(_ state: StreamState) -> String {
        switch state {
        case .streaming:
            return "Streaming"
        case .paused:
            return "Paused"
        case .starting:
            return "Starting"
        case .stopping:
            return "Stopping"
        case .stopped:
            return "Stopped"
        case .waitingForDevice:
            return "Waiting for glasses"
        }
    }

    private static func thermalLabel(_ level: ThermalLevel) -> String {
        switch level {
        case .unknown: return "unknown"
        case .none: return "none"
        case .light: return "light"
        case .moderate: return "moderate"
        case .severe: return "severe"
        case .critical: return "critical"
        case .emergency: return "emergency"
        case .shutdown: return "shutdown"
        }
    }

    private static func hingeLabel(_ state: HingeState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .closed: return "closed"
        case .open: return "open"
        }
    }
}

private enum StartRace {
    case started
    case stopped
    case timedOut
}

private enum DATFrames {
    /// Reused so a 30 minute session does not build a new context per frame.
    private static let colorContext = CIContext(options: [.cacheIntermediates: false])

    /// TODO(verify): `VideoFrame.makeUIImage()` on a `.raw` frame is upright and non-nil.
    /// The sample buffer path is only a fallback when that image is missing.
    /// UIImage conversion runs on the main thread so it still compiles if UIKit
    /// treats image drawing as main-actor work.
    /// The JPEG is downsampled in memory. It is not written to disk.
    static func cameraFrame(from frame: VideoFrame) -> CameraFrame? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                convert(frame)
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                convert(frame)
            }
        }
    }

    @MainActor
    private static func convert(_ frame: VideoFrame) -> CameraFrame? {
        autoreleasepool {
            if let image = frame.makeUIImage(), let jpeg = FrameJPEG.data(from: image) {
                let pixelWidth = Int((image.size.width * image.scale).rounded())
                let pixelHeight = Int((image.size.height * image.scale).rounded())
                let longest = max(pixelWidth, pixelHeight)
                let scale = longest > FrameJPEG.maxEdge ? Double(FrameJPEG.maxEdge) / Double(longest) : 1
                return CameraFrame(
                    capturedAt: Date(),
                    jpegData: jpeg,
                    width: max(1, Int((Double(pixelWidth) * scale).rounded())),
                    height: max(1, Int((Double(pixelHeight) * scale).rounded()))
                )
            }
            guard let pixel = CMSampleBufferGetImageBuffer(frame.sampleBuffer) else {
                return nil
            }
            let image = CIImage(cvPixelBuffer: pixel)
            let longest = max(image.extent.width, image.extent.height)
            let scaled: CIImage
            if longest > CGFloat(FrameJPEG.maxEdge), longest > 0 {
                let factor = CGFloat(FrameJPEG.maxEdge) / longest
                scaled = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            } else {
                scaled = image
            }
            guard let rendered = colorContext.createCGImage(scaled, from: scaled.extent),
                  let jpeg = FrameJPEG.data(from: rendered) else {
                return nil
            }
            return CameraFrame(
                capturedAt: Date(),
                jpegData: jpeg,
                width: rendered.width,
                height: rendered.height
            )
        }
    }
}
