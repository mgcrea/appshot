import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decode / encode / raw-pixel helpers shared by the gate and the compositor.
public enum Image {
    public static func load(_ url: URL) throws -> CGImage {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            if isGitLFSPointer(url) { throw AppShotError.gitLFSPointer(url) }
            throw AppShotError.imageDecodeFailed(url)
        }
        return image
    }

    /// Reject Git LFS pointers before anything else looks at these files.
    ///
    /// This has to run *ahead* of the gate's hash fast path, not just at decode time.
    /// A clone without `git lfs pull` has pointer files on both sides, and two pointers
    /// for the same object are byte-identical — so the fast path calls it a clean match
    /// and the gate reports every screenshot as passing. It then blows up in the
    /// compositor, or worse, doesn't.
    public static func rejectLFSPointers(_ urls: [URL]) throws {
        for url in urls where isGitLFSPointer(url) {
            throw AppShotError.gitLFSPointer(url)
        }
    }

    /// The goldens are stored in Git LFS, and a clone that has not run `git lfs pull`
    /// gets a 131-byte text pointer *still named .png*. Everything that merely checks
    /// the file exists sails straight past it.
    static func isGitLFSPointer(_ url: URL) -> Bool {
        guard
            let handle = try? FileHandle(forReadingFrom: url),
            let head = try? handle.read(upToCount: 64)
        else { return false }
        try? handle.close()
        return String(decoding: head, as: UTF8.self)
            .hasPrefix("version https://git-lfs.github.com/spec/")
    }

    /// Pixel dimensions without decoding the image — ImageIO reads them straight
    /// from the PNG header, so this is cheap enough to call on every file.
    public static func size(_ url: URL) -> (width: Int, height: Int)? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Int,
            let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    public static func write(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard
            let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw AppShotError.imageEncodeFailed(url) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw AppShotError.imageEncodeFailed(url)
        }
    }

    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard
            let dest = CGImageDestinationCreateWithData(
                data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// **Premultiplied** RGBA8 bytes, row-packed with no padding.
    ///
    /// Premultiplied is not a compromise here, it is what the gate wants:
    /// premultiplied RGB *is* the colour composited over black, which is exactly
    /// the flattening the Python gate did by hand before diffing. The alpha channel
    /// survives untouched alongside it, so the categorical alpha check still works.
    /// (CGBitmapContext cannot produce straight alpha at 8bpc anyway.)
    public struct Pixels: Sendable {
        public let width: Int
        public let height: Int
        public let bytes: [UInt8]

        public var count: Int { width * height }

        @inlinable
        public subscript(index: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let i = index * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        }
    }

    public static func pixels(_ image: CGImage) -> Pixels? {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let ctx = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        return Pixels(width: width, height: height, bytes: bytes)
    }

    /// An RGBA8 drawing context in sRGB.
    public static func context(width: Int, height: Int) -> CGContext? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// `#RRGGBB` → CGColor. Returns nil on anything else.
    public static func color(hex: String, alpha: Double = 1) -> CGColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return CGColor(
            srgbRed: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255,
            alpha: alpha)
    }
}
