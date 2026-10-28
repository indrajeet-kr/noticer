import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// JPEG bytes for an in-memory `CameraFrame`. Nothing here writes a file.
enum FrameJPEG {
    /// TODO(verify): the contract does not set a compression quality or a 512 px upload size.
    static let compressionQuality: CGFloat = 0.8

    static func data(from image: CGImage) -> Data? {
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
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    static func data(from image: UIImage) -> Data? {
        image.jpegData(compressionQuality: compressionQuality)
    }
}
