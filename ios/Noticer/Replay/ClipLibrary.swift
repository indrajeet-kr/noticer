import AVFoundation
import Foundation
import NoticerAgent
import NoticerCore

enum ClipLibraryError: LocalizedError {
    case noClips
    case noVideoTrack
    case emptyClip
    case noFrames
    case missingFixtures
    case badFixture(String)

    var errorDescription: String? {
        switch self {
        case .noClips:
            return "No clip in fixtures/clips. Add an mp4, mov, or m4v and build again."
        case .noVideoTrack:
            return "That clip has no video track."
        case .emptyClip:
            return "That clip has no duration."
        case .noFrames:
            return "Could not read frames from that clip."
        case .missingFixtures:
            return "No recorded model responses were bundled from fixtures/model-responses."
        case .badFixture(let name):
            return "Could not read the recorded response \(name)."
        }
    }
}

struct LoadedRecording {
    var client: RecordedModelClient
    var skippedTruncated: Int
}

/// Recorded clips and cached model turns bundled with the app.
enum ClipLibrary {
    /// TODO(verify): a memory cap for phone playback, not a product limit.
    /// Ninety seconds at 2 fps. Longer clips stop there.
    static let frameCap = 180

    static func videoURLs() -> [URL] {
        resourceURLs(extensions: ["mp4", "mov", "m4v"], directory: "clips")
    }

    static func makeFrameSource(for url: URL) async throws -> ReplayFrameSource {
        let frames = try await extractFrames(from: url)
        return ReplayFrameSource(frames: frames)
    }

    static func makeRecording() throws -> LoadedRecording {
        let urls = resourceURLs(extensions: ["json"], directory: "model-responses")
        guard !urls.isEmpty else {
            throw ClipLibraryError.missingFixtures
        }
        let decoder = JSONDecoder()
        var verdicts: [ModelVerdict] = []
        var skippedTruncated = 0
        for url in urls {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw ClipLibraryError.badFixture(url.lastPathComponent)
            }
            let fixture: RecordedModelFixture
            do {
                fixture = try decoder.decode(RecordedModelFixture.self, from: data)
            } catch {
                throw ClipLibraryError.badFixture(url.lastPathComponent)
            }
            do {
                verdicts.append(try fixture.makeVerdict())
            } catch ModelContractError.truncated {
                skippedTruncated += 1
            } catch {
                throw ClipLibraryError.badFixture(url.lastPathComponent)
            }
        }
        guard !verdicts.isEmpty else {
            throw ClipLibraryError.missingFixtures
        }
        return LoadedRecording(
            client: RecordedModelClient(verdicts: verdicts),
            skippedTruncated: skippedTruncated
        )
    }

    /// Samples the clip at the product frame rate with `AVAssetImageGenerator`.
    static func extractFrames(from url: URL) async throws -> [CameraFrame] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.first != nil else {
            throw ClipLibraryError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else {
            throw ClipLibraryError.emptyClip
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let seconds = duration.seconds
        let step = 1.0 / Double(SessionLimits.requestedFramesPerSecond)
        let anchor = Date().addingTimeInterval(-seconds)
        var frames: [CameraFrame] = []
        var time = 0.0
        while time < seconds, frames.count < frameCap {
            let sample = CMTime(seconds: min(time, seconds - 0.001), preferredTimescale: 600)
            do {
                let (image, _) = try await generator.image(at: sample)
                if let jpeg = FrameJPEG.data(from: image) {
                    frames.append(
                        CameraFrame(
                            capturedAt: anchor.addingTimeInterval(time),
                            jpegData: jpeg,
                            width: image.width,
                            height: image.height
                        )
                    )
                }
            } catch {
                // One bad timestamp should not drop the rest of the clip.
            }
            time += step
        }
        guard !frames.isEmpty else {
            throw ClipLibraryError.noFrames
        }
        return frames
    }

    private static func resourceURLs(extensions: [String], directory: String) -> [URL] {
        var found: [URL] = []
        if let folder = Bundle.main.url(forResource: directory, withExtension: nil) {
            let nested = (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            )) ?? []
            found.append(contentsOf: nested)
        }
        let allowed = Set(extensions.map { $0.lowercased() })
        for ext in extensions {
            found.append(contentsOf: Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: directory) ?? [])
            found.append(contentsOf: Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [])
        }
        var seen = Set<String>()
        return found
            .filter { allowed.contains($0.pathExtension.lowercased()) }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
