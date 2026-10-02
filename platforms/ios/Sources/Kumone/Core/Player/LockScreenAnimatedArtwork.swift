#if os(iOS)
import AVFoundation
import MediaPlayer
import UIKit

/// iOS 26 lock-screen "immersive" cover: the system plays a looping video behind
/// the Now Playing controls (the same mechanism Apple Music uses). Third-party
/// apps hand it an `MPMediaItemAnimatedArtwork`; for songs that only have a still
/// cover we render a short seamless loop (slow breathing zoom) in 3:4 and 1:1.
@available(iOS 26.0, *)
enum LockScreenAnimatedArtwork {
    private static let variants: [(name: String, size: CGSize)] = [
        ("3x4", CGSize(width: 720, height: 960)),
        ("1x1", CGSize(width: 960, height: 960))
    ]

    /// Animated artwork keyed by variant name ("3x4", "1x1").
    static func artworks(for image: UIImage, key: String) async -> [String: MPMediaItemAnimatedArtwork] {
        var result: [String: MPMediaItemAnimatedArtwork] = [:]
        for variant in variants {
            let identifier = "\(stableHash(key))-\(variant.name)"
            guard let url = await renderVideo(image: image, size: variant.size, identifier: identifier) else { continue }
            let preview = aspectFill(image, size: variant.size, scale: 1)
            let artwork = MPMediaItemAnimatedArtwork(
                artworkID: identifier,
                previewImageRequestHandler: { _ in preview },
                videoAssetFileURLRequestHandler: { _ in url }
            )
            result[variant.name] = artwork
        }
        return result
    }

    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(hash, radix: 16)
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LockScreenArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func trimCache(keeping keep: Int = 16) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for file in sorted.dropFirst(keep) { try? fm.removeItem(at: file) }
    }

    private static func aspectFill(_ image: UIImage, size: CGSize, scale: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let ratio = max(size.width / image.size.width, size.height / image.size.height) * scale
            let drawSize = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            image.draw(in: CGRect(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2,
                                  width: drawSize.width, height: drawSize.height))
        }
    }

    private static func renderVideo(image: UIImage, size: CGSize, identifier: String) async -> URL? {
        let url = directory.appendingPathComponent("\(identifier).mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return await Task.detached(priority: .utility) { () -> URL? in
            try? FileManager.default.removeItem(at: url)
            guard let cgImage = image.cgImage,
                  let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
            let width = Int(size.width)
            let height = Int(size.height)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 3_000_000]
            ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height
                ])
            guard writer.canAdd(input) else { return nil }
            writer.add(input)
            guard writer.startWriting() else { return nil }
            writer.startSession(atSourceTime: .zero)

            let fps: Int32 = 24
            let frames = 96
            let imageWidth = CGFloat(cgImage.width)
            let imageHeight = CGFloat(cgImage.height)
            let fill = max(CGFloat(width) / imageWidth, CGFloat(height) / imageHeight)
            for index in 0..<frames {
                while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.004) }
                guard let pool = adaptor.pixelBufferPool else { break }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { break }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let context = CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer),
                    width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                    // A full breathing cycle (in and back out) makes the loop seamless.
                    let phase = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(frames))
                    let zoom = fill * CGFloat(1.0 + 0.07 * phase)
                    let drawWidth = imageWidth * zoom
                    let drawHeight = imageHeight * zoom
                    context.interpolationQuality = .high
                    context.draw(cgImage, in: CGRect(x: (CGFloat(width) - drawWidth) / 2,
                                                     y: (CGFloat(height) - drawHeight) / 2,
                                                     width: drawWidth, height: drawHeight))
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps))
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            trimCache()
            return url
        }.value
    }
}
#endif
