import CoreGraphics
import Foundation
import ImageIO
import NoticerCore

/// JPEG bytes to a small gray plane. ImageIO only: no Vision request and no Core ML.
/// The bitmap lives inside an autorelease pool and is not written to disk.
enum LumaExtractor {
    static func plane(jpeg: Data, maxEdge: Int, samples: inout [UInt8]) -> LumaPlane? {
        let image: CGImage? = autoreleasepool {
            guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: max(8, maxEdge),
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let image else {
            return nil
        }
        return fill(&samples, from: image)
    }

    private static func fill(_ samples: inout [UInt8], from image: CGImage) -> LumaPlane? {
        let width = image.width
        let height = image.height
        guard width >= 3, height >= 3 else {
            return nil
        }
        let count = width * height
        if samples.count != count {
            samples = [UInt8](repeating: 0, count: count)
        }
        let drew = samples.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        return LumaPlane(width: width, height: height, samples: samples)
    }
}
