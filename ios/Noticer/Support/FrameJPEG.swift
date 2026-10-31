import CoreGraphics
import Foundation
import ImageIO
import NoticerCore
import UIKit
import UniformTypeIdentifiers

/// JPEG bytes for an in-memory `CameraFrame`. Nothing here writes a file.
enum FrameJPEG {
    static let compressionQuality = CGFloat(LatencyTuning.default.smallerPayloads ? LatencyTuning.default.jpegQuality : SignalGateTuning.jpegQuality)
    static let maxEdge = LatencyTuning.default.smallerPayloads ? LatencyTuning.default.uploadMaxEdge : SignalGateTuning.uploadMaxEdge

    static func data(from image: CGImage, latency: LatencyTuning = .default) -> Data? {
        let targetEdge = latency.smallerPayloads ? latency.uploadMaxEdge : SignalGateTuning.uploadMaxEdge
        let quality = CGFloat(latency.smallerPayloads ? latency.jpegQuality : SignalGateTuning.jpegQuality)
        return autoreleasepool {
            let sized = resized(image, maxEdge: targetEdge)
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: quality
            ]
            CGImageDestinationAddImage(destination, sized, options as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                return nil
            }
            return data as Data
        }
    }

    static func data(from image: UIImage, latency: LatencyTuning = .default) -> Data? {
        let quality = CGFloat(latency.smallerPayloads ? latency.jpegQuality : SignalGateTuning.jpegQuality)
        guard let cgImage = image.cgImage else {
            return autoreleasepool {
                image.jpegData(compressionQuality: quality)
            }
        }
        return data(from: cgImage, latency: latency)
    }

    /// Longest side above `maxEdge` is scaled down. Smaller images are unchanged.
    static func resized(_ image: CGImage, maxEdge: Int) -> CGImage {
        let width = image.width
        let height = image.height
        let longest = max(width, height)
        guard longest > maxEdge, longest > 0 else {
            return image
        }
        let scale = Double(maxEdge) / Double(longest)
        let newWidth = max(1, Int((Double(width) * scale).rounded()))
        let newHeight = max(1, Int((Double(height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? image
    }
}
