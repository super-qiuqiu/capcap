import AppKit
import CoreVideo
import VideoToolbox

final class DisplaySnapshot {
    let displayID: CGDirectDisplayID
    let pixelBuffer: CVPixelBuffer?

    private let imageLock = NSLock()
    private var cachedImage: CGImage?

    init(displayID: CGDirectDisplayID, pixelBuffer: CVPixelBuffer) {
        self.displayID = displayID
        self.pixelBuffer = pixelBuffer
        self.cachedImage = nil
    }

    init(displayID: CGDirectDisplayID, image: CGImage) {
        self.displayID = displayID
        self.pixelBuffer = nil
        self.cachedImage = image
    }

    func cgImage() -> CGImage? {
        imageLock.lock()
        defer { imageLock.unlock() }

        if let cachedImage {
            return cachedImage
        }
        guard let pixelBuffer else {
            return nil
        }

        let signpost = PerformanceSignposts.begin("ScreenFrameCGImageConversion")
        defer { PerformanceSignposts.end("ScreenFrameCGImageConversion", signpost) }

        var image: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        guard status == noErr, let image else {
            NSLog("capcap: Screen frame cache image conversion failed: \(status)")
            return nil
        }

        cachedImage = image
        return image
    }

    func crop(captureRect: CGRect, screen: NSScreen) -> NSImage? {
        guard let image = cgImage() else { return nil }
        return ScreenCapturer.crop(from: image, captureRect: captureRect, screen: screen)
    }
}
