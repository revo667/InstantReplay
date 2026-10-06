import AVFoundation

enum MovieRecorderError: LocalizedError {
    case invalidVideoFormat

    var errorDescription: String? {
        switch self {
        case .invalidVideoFormat: "The encoder produced a frame without a video format."
        }
    }
}

final class MovieRecorder: @unchecked Sendable {
    var onSegmentFinished: ((URL, Error?) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "instantreplay.recorder", qos: .userInitiated)
    private var isActive = false
    private var baseName = ""
    private var partNumber = 1
    private var mix = ClipAudioMix(systemGain: nil, microphoneGain: nil)
    private var segment: RecordingSegment?

    func start(baseName: String, mix: ClipAudioMix) {
        queue.async { [self] in
            if let segment { close(segment, completion: nil) }
            self.baseName = baseName
            self.mix = mix
            partNumber = 1
            segment = nil
            isActive = true
        }
    }

    func updateMix(_ mix: ClipAudioMix) {
        queue.async { [self] in self.mix = mix }
    }

    func beginNewSegment() {
        queue.sync {
            guard let segment else { return }
            self.segment = nil
            partNumber += 1
            close(segment, completion: nil)
        }
    }

    func finish() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                isActive = false
                guard let segment else {
                    continuation.resume()
                    return
                }
                self.segment = nil
                close(segment) { continuation.resume() }
            }
        }
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        queue.async { [self] in
            guard isActive else { return }
            if segment == nil {
                guard sample.isKeyFrame else { return }
                openSegment(startingWith: sample)
            }
            guard let segment else { return }
            segment.appendVideo(sample)
            if let error = segment.failure { fail(with: error) }
        }
    }

    func appendAudio(_ sample: CMSampleBuffer, track: AudioTrack) {
        queue.async { [self] in
            guard isActive, let segment, let gain = gain(for: track) else { return }
            segment.appendAudio(sample.applyingGain(gain), track: track)
        }
    }

    private func gain(for track: AudioTrack) -> Float? {
        switch track {
        case .system: mix.systemGain
        case .microphone: mix.microphoneGain
        }
    }

    private func openSegment(startingWith sample: CMSampleBuffer) {
        let url = Settings.recordingURL(baseName: baseName, part: partNumber)
        let tracks = AudioTrack.allCases.filter { gain(for: $0) != nil }
        do {
            segment = try RecordingSegment(url: url, firstVideo: sample, audioTracks: tracks)
        } catch {
            fail(with: error)
        }
    }

    private func fail(with error: Error) {
        isActive = false
        segment = nil
        onFailure?(error)
    }

    private func close(_ segment: RecordingSegment, completion: (() -> Void)?) {
        let url = segment.url
        segment.finish { [weak self] error in
            self?.onSegmentFinished?(url, error)
            completion?()
        }
    }
}

private final class RecordingSegment {
    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInputs: [AudioTrack: AVAssetWriterInput]
    private let startTime: CMTime
    private let fallbackFrameDuration = CMTime(value: 1, timescale: 60)
    private var endTime: CMTime

    private static let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 192_000,
    ]

    init(url: URL, firstVideo: CMSampleBuffer, audioTracks: [AudioTrack]) throws {
        guard let videoFormat = firstVideo.formatDescription else { throw MovieRecorderError.invalidVideoFormat }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false
        writer.movieFragmentInterval = CMTime(value: 10, timescale: 1)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw ClipWriterError.writerFailed }
        writer.add(videoInput)

        var audioInputs: [AudioTrack: AVAssetWriterInput] = [:]
        for track in audioTracks {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { continue }
            writer.add(input)
            audioInputs[track] = input
        }

        guard writer.startWriting() else { throw writer.error ?? ClipWriterError.writerFailed }
        startTime = firstVideo.presentationTimeStamp
        writer.startSession(atSourceTime: startTime)

        self.url = url
        self.writer = writer
        self.videoInput = videoInput
        self.audioInputs = audioInputs
        endTime = startTime
    }

    var failure: Error? {
        writer.status == .failed ? writer.error ?? ClipWriterError.writerFailed : nil
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        guard writer.status == .writing, videoInput.isReadyForMoreMediaData, videoInput.append(sample) else { return }
        let duration = sample.duration.isValid ? sample.duration : fallbackFrameDuration
        endTime = max(endTime, sample.presentationTimeStamp + duration)
    }

    func appendAudio(_ sample: CMSampleBuffer, track: AudioTrack) {
        guard writer.status == .writing,
              sample.presentationTimeStamp >= startTime,
              let input = audioInputs[track],
              input.isReadyForMoreMediaData else { return }
        input.append(sample)
    }

    func finish(completion: @escaping (Error?) -> Void) {
        guard writer.status == .writing else {
            completion(failure)
            return
        }
        videoInput.markAsFinished()
        audioInputs.values.forEach { $0.markAsFinished() }
        writer.endSession(atSourceTime: endTime)
        writer.finishWriting { [writer] in
            completion(writer.status == .completed ? nil : writer.error ?? ClipWriterError.writerFailed)
        }
    }
}
