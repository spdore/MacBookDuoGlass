import AppKit
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit

final class ScreenCaptureService: NSObject, SCStreamOutput, SCStreamDelegate {
    typealias FrameHandler = (CVPixelBuffer) -> Void
    typealias StateHandler = (Result<Void, Error>) -> Void

    // ScreenCaptureKit must never deliver frames on the AppKit main queue.
    // The main queue is reserved for window state and the Metal view.
    private let outputQueue = DispatchQueue(
        label: "com.spdor.MacBookDuoGlass.screen-output",
        qos: .userInteractive
    )
    private var stream: SCStream?
    private var currentDisplayID: CGDirectDisplayID?
    private var frameHandler: FrameHandler?
    private var stateHandler: StateHandler?
    private(set) var isRunning = false
    private(set) var isStarting = false
    private var generation = 0
    private var receivedCompleteFrame = false

    func start(frameHandler: @escaping FrameHandler, stateHandler: @escaping StateHandler) {
        stop()
        self.frameHandler = frameHandler
        self.stateHandler = stateHandler

        isStarting = true
        let token = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.startStream(token: token)
            } catch {
                guard token == self.generation else { return }
                self.isStarting = false
                self.stateHandler?(.failure(error))
            }
        }
    }

    func stop() {
        generation += 1
        isStarting = false
        let stream = self.stream
        self.stream = nil
        self.isRunning = false
        receivedCompleteFrame = false
        guard let stream else { return }
        Task {
            try? await stream.stopCapture()
        }
    }

    func restart() {
        guard let frameHandler, let stateHandler else { return }
        start(frameHandler: frameHandler, stateHandler: stateHandler)
    }

    @MainActor
    private func startStream(token: Int) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw MacBookDuoGlassError.screenCapturePermissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard token == generation else { return }
        guard let screen = NSScreen.screens.first(where: { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return id?.uint32Value == CGMainDisplayID() && CGDisplayIsBuiltin(CGMainDisplayID()) != 0
        }) ?? NSScreen.screens.first(where: { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayIsBuiltin(id.uint32Value) != 0
        }) else {
            throw MacBookDuoGlassError.noBuiltInDisplay
        }

        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == displayID.uint32Value }) else {
            throw MacBookDuoGlassError.noBuiltInDisplay
        }

        let excludedApplications = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        guard !excludedApplications.isEmpty else {
            throw MacBookDuoGlassError.screenCaptureUnavailable("无法确认覆盖窗口所属进程已被排除，已停止采集以防画面循环磨砂。")
        }
        NSLog("Duo capture: excluding own PID %d (%d matches)", ProcessInfo.processInfo.processIdentifier, excludedApplications.count)
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        // Keep the capture pipeline shallow so old screen frames cannot sit
        // in front of the newest lid-angle sample.
        configuration.queueDepth = 2
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = false
        }
        configuration.ignoreGlobalClipSingleWindow = true

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await newStream.startCapture()
        guard token == generation else {
            try? await newStream.stopCapture()
            return
        }

        self.stream = newStream
        self.currentDisplayID = display.displayID
        self.isRunning = true
        self.isStarting = false
        await MainActor.run {
            self.stateHandler?(.success(()))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard stream === self.stream,
              outputType == .screen,
              sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        if !receivedCompleteFrame {
            receivedCompleteFrame = true
            NSLog("Duo capture: first complete frame %dx%d", CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
        }
        frameHandler?(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard stream === self.stream else { return }
        isRunning = false
        DispatchQueue.main.async { [weak self] in
            self?.stateHandler?(.failure(error))
        }
    }
}
