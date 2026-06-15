import AppKit
import Vision

/// Detects sensitive regions (text, optionally QR codes) in screenshots for automatic mosaicing.
struct AutoMosaicDetector {
    enum DetectionError: Error {
        case imageUnavailable
        case visionRequestFailed
    }

    /// Detect sensitive regions in an image that should be mosaiced.
    ///
    /// - Parameters:
    ///   - image: The screenshot image to scan
    ///   - detectText: Whether to detect text regions (default: true)
    ///   - detectBarcodes: Whether to detect QR codes and barcodes (default: false)
    ///   - completion: Called with rects in the image's coordinate space.
    static func detectSensitiveRegions(
        in image: NSImage,
        detectText: Bool = true,
        detectBarcodes: Bool = false,
        completion: @escaping (Result<[NSRect], DetectionError>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cgImage = image.cgImagePreservingBacking() else {
                DispatchQueue.main.async {
                    completion(.failure(.imageUnavailable))
                }
                return
            }

            let imageSize = image.size
            var detectedRects: [NSRect] = []

            do {
                if detectText {
                    let textRects = try detectTextRegions(in: cgImage, imageSize: imageSize)
                    detectedRects.append(contentsOf: textRects)
                }

                if detectBarcodes {
                    let barcodeRects = try detectBarcodeRegions(in: cgImage, imageSize: imageSize)
                    detectedRects.append(contentsOf: barcodeRects)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(.visionRequestFailed))
                }
                return
            }

            // Merge nearby regions to avoid over-segmentation
            let merged = mergeNearbyRects(detectedRects, threshold: 10)

            DispatchQueue.main.async {
                completion(.success(merged))
            }
        }
    }

    // MARK: - Text Detection

    private static func detectTextRegions(in cgImage: CGImage, imageSize: NSSize) throws -> [NSRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            throw DetectionError.visionRequestFailed
        }

        guard let observations = request.results as? [VNRecognizedTextObservation] else {
            return []
        }

        return observations
            .filter { $0.confidence >= 0.5 }
            .map { convertVisionRectToImageRect($0.boundingBox, imageSize: imageSize) }
    }

    // MARK: - Barcode Detection

    private static func detectBarcodeRegions(in cgImage: CGImage, imageSize: NSSize) throws -> [NSRect] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            throw DetectionError.visionRequestFailed
        }

        guard let observations = request.results as? [VNBarcodeObservation] else {
            return []
        }

        return observations.map { convertVisionRectToImageRect($0.boundingBox, imageSize: imageSize) }
    }

    // MARK: - Coordinate Conversion

    /// Convert Vision's normalized coordinates (0-1, origin bottom-left) to AppKit image coordinates (pixel, origin top-left).
    private static func convertVisionRectToImageRect(_ visionRect: CGRect, imageSize: NSSize) -> NSRect {
        let x = visionRect.origin.x * imageSize.width
        let y = (1 - visionRect.origin.y - visionRect.height) * imageSize.height  // Flip Y
        let w = visionRect.width * imageSize.width
        let h = visionRect.height * imageSize.height
        return NSRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Region Merging

    /// Merge rectangles that are within threshold distance of each other.
    private static func mergeNearbyRects(_ rects: [NSRect], threshold: CGFloat) -> [NSRect] {
        guard !rects.isEmpty else { return [] }

        // Group rects into clusters where each rect is within threshold of at least one other in the cluster
        var clusters: [[NSRect]] = []

        for rect in rects {
            // Expand rect by threshold to create an "influence zone"
            let expanded = rect.insetBy(dx: -threshold, dy: -threshold)

            // Find clusters this rect overlaps with
            var overlappingClusters: [Int] = []
            for (index, cluster) in clusters.enumerated() {
                for existing in cluster {
                    let existingExpanded = existing.insetBy(dx: -threshold, dy: -threshold)
                    if expanded.intersects(existingExpanded) {
                        overlappingClusters.append(index)
                        break
                    }
                }
            }

            if overlappingClusters.isEmpty {
                // Create new cluster
                clusters.append([rect])
            } else if overlappingClusters.count == 1 {
                // Add to existing cluster
                clusters[overlappingClusters[0]].append(rect)
            } else {
                // Merge multiple clusters
                var merged: [NSRect] = [rect]
                for idx in overlappingClusters.reversed() {
                    merged.append(contentsOf: clusters[idx])
                    clusters.remove(at: idx)
                }
                clusters.append(merged)
            }
        }

        // Convert each cluster to a single bounding rect
        return clusters.map { cluster in
            guard let first = cluster.first else { return .zero }
            return cluster.dropFirst().reduce(first) { $0.union($1) }
        }
    }
}
