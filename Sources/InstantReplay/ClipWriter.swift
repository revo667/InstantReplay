import Accelerate
import AVFoundation

struct ClipAudioMix {
    let systemGain: Float?
    let microphoneGain: Float?
}

enum ClipWriterError: LocalizedError {
    case emptyBuffer
    case writerFailed

    var errorDescription: String? {
        switch self {
        case .emptyBuffer: "The replay buffer is empty."
        case .writerFailed: "Could not write the clip file."
        }
    }
}

enum ClipWriter {
    static func write(_ snapshot: ReplaySnapshot, mix: ClipAudioMix, fileType: AVFileType, to url: URL) async throws {
        guard let firstVideo = snapshot.video.first,
              let lastVideo = snapshot.video.last,
              let videoFormat = firstVideo.formatDescription else { throw ClipWriterError.emptyBuffer }

        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        var feeds: [(input: AVAssetWriterInput, samples: [CMSampleBuffer])] = [(videoInput, snapshot.video)]
        let audioTracks: [([CMSampleBuffer], Float?)] = [
            (snapshot.systemAudio, mix.systemGain),
            (snapshot.microphone, mix.microphoneGain),
        ]
        for (rawSamples, gain) in audioTracks {
            guard let gain, !rawSamples.isEmpty else { continue }
            let samples = rawSamples.map { $0.applyingGain(gain) }
            guard let input = makeAudioInput(for: samples), writer.canAdd(input) else { continue }
            writer.add(input)
            feeds.append((input, samples))
        }

        guard writer.startWriting() else { throw writer.error ?? ClipWriterError.writerFailed }
        writer.startSession(atSourceTime: firstVideo.presentationTimeStamp)

        await withTaskGroup(of: Void.self) { group in
            for feed in feeds {
                group.addTask { await append(feed.samples, to: feed.input) }
            }
        }

        let lastDuration = lastVideo.duration.isValid ? lastVideo.duration : CMTime(value: 1, timescale: 60)
        writer.endSession(atSourceTime: lastVideo.presentationTimeStamp + lastDuration)
        await writer.finishWriting()

        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? ClipWriterError.writerFailed
        }
    }

    private static func makeAudioInput(for samples: [CMSampleBuffer]) -> AVAssetWriterInput? {
        guard let format = samples.first?.formatDescription,
              let description = format.audioStreamBasicDescription else { return nil }
        let channels = min(max(Int(description.mChannelsPerFrame), 1), 2)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: description.mSampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 2 ? 192_000 : 96_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        return input
    }

    private static func append(_ samples: [CMSampleBuffer], to input: AVAssetWriterInput) async {
        let queue = DispatchQueue(label: "instantreplay.writer.\(input.mediaType.rawValue)")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var index = 0
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard index < samples.count, input.append(samples[index]) else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    index += 1
                }
            }
        }
    }
}

extension CMSampleBuffer {
    func applyingGain(_ gain: Float) -> CMSampleBuffer {
        guard gain != 1,
              let description = formatDescription?.audioStreamBasicDescription,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              description.mBitsPerChannel == 32,
              let copy = deepCopiedAudio(),
              let data = copy.dataBuffer else { return self }
        var totalLength = 0
        var pointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(data, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &pointer)
        guard status == kCMBlockBufferNoErr, let pointer else { return self }
        let count = vDSP_Length(totalLength / MemoryLayout<Float>.size)
        pointer.withMemoryRebound(to: Float.self, capacity: Int(count)) { samples in
            var scale = gain
            var low: Float = -1
            var high: Float = 1
            vDSP_vsmul(samples, 1, &scale, samples, 1, count)
            vDSP_vclip(samples, 1, &low, &high, samples, 1, count)
        }
        return copy
    }
}
