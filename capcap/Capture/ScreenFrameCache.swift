import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import VideoToolbox

final class ScreenFrameCache {
    static let shared = ScreenFrameCache()

    private struct DisplayRequest {
        let displayID: CGDirectDisplayID
        let displayBounds: CGRect
        let scale: CGFloat
    }

    struct SnapshotFrame {
        let displayID: CGDirectDisplayID
        let pixelBuffer: CVPixelBuffer
        let receivedUptimeNanoseconds: UInt64
    }

    private final class StreamSession {
        let displayID: CGDirectDisplayID
        let stream: SCStream
        let output: ScreenFrameStreamOutput

        init(displayID: CGDirectDisplayID, stream: SCStream, output: ScreenFrameStreamOutput) {
            self.displayID = displayID
            self.stream = stream
            self.output = output
        }
    }

    private let stateQueue = DispatchQueue(label: "capcap.screen-frame-cache.state", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "capcap.screen-frame-cache.samples", qos: .userInteractive)
    private let maxFramesPerDisplay = 2
    private let maximumFrameAgeNanoseconds: UInt64 = 250_000_000

    private var sessions: [CGDirectDisplayID: StreamSession] = [:]
    private var frames: [CGDirectDisplayID: [SnapshotFrame]] = [:]
    private var generation: UInt64 = 0
    private var isStarting = false
    private var restartWorkItem: DispatchWorkItem?

    private init() {}

    func start() {
        guard AppPermissions.screenRecordingGranted else { return }

        let shouldStart = stateQueue.sync { () -> Bool in
            if isStarting || !sessions.isEmpty {
                return false
            }
            isStarting = true
            generation &+= 1
            return true
        }

        guard shouldStart else { return }
        let startGeneration = stateQueue.sync { generation }

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.startStreams(generation: startGeneration)
        }
    }

    func restart() {
        restartWorkItem?.cancel()
        restartWorkItem = nil

        let oldSessions = stateQueue.sync { () -> [StreamSession] in
            generation &+= 1
            isStarting = false
            frames.removeAll(keepingCapacity: false)
            let old = Array(sessions.values)
            sessions.removeAll(keepingCapacity: false)
            return old
        }

        stop(sessions: oldSessions)
        start()
    }

    func stop() {
        restartWorkItem?.cancel()
        restartWorkItem = nil

        let oldSessions = stateQueue.sync { () -> [StreamSession] in
            generation &+= 1
            isStarting = false
            frames.removeAll(keepingCapacity: false)
            let old = Array(sessions.values)
            sessions.removeAll(keepingCapacity: false)
            return old
        }

        stop(sessions: oldSessions)
    }

    func snapshotImages(for screens: [NSScreen]) -> [CGDirectDisplayID: CGImage] {
        let selectedFrames = snapshotFrames(for: screens)
        guard !selectedFrames.isEmpty else { return [:] }

        let pairs = Array(selectedFrames)
        let lock = NSLock()
        var images: [CGDirectDisplayID: CGImage] = [:]
        DispatchQueue.concurrentPerform(iterations: pairs.count) { index in
            let (displayID, frame) = pairs[index]
            let snapshot = DisplaySnapshot(displayID: displayID, pixelBuffer: frame.pixelBuffer)
            guard let image = snapshot.cgImage() else { return }
            lock.lock()
            images[displayID] = image
            lock.unlock()
        }
        return images
    }

    func snapshotFrames(for screens: [NSScreen]) -> [CGDirectDisplayID: SnapshotFrame] {
        start()

        let signpost = PerformanceSignposts.begin("ScreenFrameCacheSnapshotFrames")
        defer { PerformanceSignposts.end("ScreenFrameCacheSnapshotFrames", signpost) }

        let displayIDs = screens.compactMap { screen in
            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }
        guard !displayIDs.isEmpty else { return [:] }

        return stateQueue.sync { () -> [CGDirectDisplayID: SnapshotFrame] in
            var selected: [CGDirectDisplayID: SnapshotFrame] = [:]
            let now = DispatchTime.now().uptimeNanoseconds
            for displayID in displayIDs {
                guard let frame = frames[displayID]?.last,
                      now >= frame.receivedUptimeNanoseconds,
                      now - frame.receivedUptimeNanoseconds <= maximumFrameAgeNanoseconds
                else {
                    continue
                }
                selected[displayID] = frame
            }
            return selected
        }
    }

    private func startStreams(generation startGeneration: UInt64) async {
        do {
            let displayRequests = await MainActor.run {
                NSScreen.screens.compactMap { screen -> DisplayRequest? in
                    guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                        return nil
                    }
                    return DisplayRequest(
                        displayID: displayID,
                        displayBounds: CGDisplayBounds(displayID),
                        scale: max(screen.backingScaleFactor, 1)
                    )
                }
            }
            guard !displayRequests.isEmpty else {
                finishStarting(generation: startGeneration, sessions: [])
                return
            }

            let content = try await SCShareableContent.current
            var preparedSessions: [StreamSession] = []

            for request in displayRequests {
                guard let display = content.displays.first(where: { $0.displayID == request.displayID }) else {
                    continue
                }

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = max(Int(ceil(request.displayBounds.width * request.scale)), 1)
                config.height = max(Int(ceil(request.displayBounds.height * request.scale)), 1)
                config.minimumFrameInterval = .zero
                config.queueDepth = 2
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.capturesAudio = false
                config.showsCursor = false
                config.captureResolution = .best
                config.shouldBeOpaque = true

                let output = ScreenFrameStreamOutput(displayID: request.displayID, generation: startGeneration)
                output.onFrame = { [weak self] displayID, generation, pixelBuffer in
                    self?.recordFrame(
                        displayID: displayID,
                        generation: generation,
                        pixelBuffer: pixelBuffer
                    )
                }
                output.onStopped = { [weak self] displayID, generation, error in
                    self?.handleStreamStopped(displayID: displayID, generation: generation, error: error)
                }

                let stream = SCStream(filter: filter, configuration: config, delegate: output)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
                try await stream.startCapture()
                preparedSessions.append(StreamSession(displayID: request.displayID, stream: stream, output: output))
            }

            finishStarting(generation: startGeneration, sessions: preparedSessions)
        } catch {
            NSLog("capcap: Screen frame cache failed to start: \(error)")
            finishStarting(generation: startGeneration, sessions: [])
        }
    }

    private func finishStarting(generation startGeneration: UInt64, sessions preparedSessions: [StreamSession]) {
        let sessionsToStop = stateQueue.sync { () -> [StreamSession] in
            guard startGeneration == generation else {
                return preparedSessions
            }

            isStarting = false
            sessions = Dictionary(uniqueKeysWithValues: preparedSessions.map { ($0.displayID, $0) })
            return []
        }

        stop(sessions: sessionsToStop)
    }

    private func recordFrame(
        displayID: CGDirectDisplayID,
        generation frameGeneration: UInt64,
        pixelBuffer: CVPixelBuffer
    ) {
        stateQueue.async {
            guard frameGeneration == self.generation else { return }

            var displayFrames = self.frames[displayID, default: []]
            displayFrames.append(SnapshotFrame(
                displayID: displayID,
                pixelBuffer: pixelBuffer,
                receivedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            ))
            if displayFrames.count > self.maxFramesPerDisplay {
                displayFrames.removeFirst(displayFrames.count - self.maxFramesPerDisplay)
            }
            self.frames[displayID] = displayFrames
        }
    }

    private func handleStreamStopped(displayID: CGDirectDisplayID, generation stoppedGeneration: UInt64, error: Error?) {
        if let error {
            NSLog("capcap: Screen frame cache stream stopped for display \(displayID): \(error)")
        }

        let shouldRestart = stateQueue.sync { () -> Bool in
            guard stoppedGeneration == generation else { return false }
            sessions[displayID] = nil
            frames[displayID] = nil
            return !isStarting
        }

        if shouldRestart {
            scheduleRestart()
        }
    }

    private func scheduleRestart() {
        DispatchQueue.main.async {
            self.restartWorkItem?.cancel()

            let item = DispatchWorkItem { [weak self] in
                self?.restart()
            }
            self.restartWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: item)
        }
    }

    private func stop(sessions oldSessions: [StreamSession]) {
        guard !oldSessions.isEmpty else { return }

        Task.detached(priority: .utility) {
            for session in oldSessions {
                try? await session.stream.stopCapture()
            }
        }
    }

}

private final class ScreenFrameStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let displayID: CGDirectDisplayID
    let generation: UInt64
    var onFrame: ((CGDirectDisplayID, UInt64, CVPixelBuffer) -> Void)?
    var onStopped: ((CGDirectDisplayID, UInt64, Error?) -> Void)?

    init(displayID: CGDirectDisplayID, generation: UInt64) {
        self.displayID = displayID
        self.generation = generation
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let attachments = Self.attachments(for: sampleBuffer),
              Self.isUsableFrame(attachments)
        else {
            return
        }

        onFrame?(displayID, generation, pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(displayID, generation, error)
    }

    private static func attachments(for sampleBuffer: CMSampleBuffer) -> [SCStreamFrameInfo: Any]? {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]] else {
            return nil
        }
        return attachmentsArray.first
    }

    private static func isUsableFrame(_ attachments: [SCStreamFrameInfo: Any]) -> Bool {
        guard let rawStatus = integerValue(attachments[.status]),
              let status = SCFrameStatus(rawValue: rawStatus)
        else {
            return false
        }
        return status == .complete || status == .started || status == .idle
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}
