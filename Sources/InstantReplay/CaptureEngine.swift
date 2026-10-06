import CoreGraphics
import CoreMedia
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display available to capture."
        }
    }
}

final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    var onUnexpectedStop: ((Error) -> Void)?
    private(set) var isRunning = false
    private(set) var displayID: CGDirectDisplayID?

    private let buffer: ReplayBuffer
    private let recorder: MovieRecorder
    private var stream: SCStream?
    private var encoder: VideoEncoder?
    private let videoQueue = DispatchQueue(label: "instantreplay.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "instantreplay.capture.audio", qos: .userInteractive)

    init(buffer: ReplayBuffer, recorder: MovieRecorder) {
        self.buffer = buffer
        self.recorder = recorder
    }

    func start(options: CaptureOptions) async throws {
        await stop()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let size = Settings.outputSize(native: pixelSize(of: display), quality: options.quality, codec: options.codec)
        displayID = display.displayID

        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate))
        configuration.pixelFormat = options.codec.capturePixelFormat
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.queueDepth = 8
        configuration.showsCursor = true
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = options.includeMicrophone
        configuration.microphoneCaptureDeviceID = options.microphoneID

        let encoder = try VideoEncoder(
            codec: options.codec,
            width: size.width,
            height: size.height,
            frameRate: options.frameRate,
            bitRate: options.bitRateMbps * 1_000_000
        ) { [buffer, recorder] sample in
            buffer.appendVideo(sample)
            recorder.appendVideo(sample)
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        if options.includeMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
        }

        buffer.reset()
        recorder.beginNewSegment()
        videoQueue.sync { self.encoder = encoder }
        self.stream = stream

        do {
            try await stream.startCapture()
        } catch {
            teardown()
            throw error
        }
        isRunning = true
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        teardown()
    }

    func updateBitRate(mbps: Int) {
        videoQueue.async { [weak self] in
            self?.encoder?.setBitRate(mbps * 1_000_000)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            handleScreenFrame(sampleBuffer)
        case .audio:
            handleAudio(sampleBuffer, track: .system)
        case .microphone:
            handleAudio(sampleBuffer, track: .microphone)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard stream === self.stream else { return }
        teardown()
        onUnexpectedStop?(error)
    }

    private func handleScreenFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        encoder?.encode(pixelBuffer, at: sampleBuffer.presentationTimeStamp, duration: sampleBuffer.duration)
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer, track: AudioTrack) {
        let sample = sampleBuffer.deepCopiedAudio() ?? sampleBuffer
        buffer.appendAudio(sample, track: track)
        recorder.appendAudio(sample, track: track)
    }

    private func teardown() {
        stream = nil
        isRunning = false
        videoQueue.sync {
            encoder?.invalidate()
            encoder = nil
        }
    }

    private func pixelSize(of display: SCDisplay) -> (width: Int, height: Int) {
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            return (mode.pixelWidth & ~1, mode.pixelHeight & ~1)
        }
        return (display.width * 2, display.height * 2)
    }
}
