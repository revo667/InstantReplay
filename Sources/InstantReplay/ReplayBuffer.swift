import CoreMedia
import Foundation

enum AudioTrack {
    case system
    case microphone
}

struct ReplaySnapshot {
    let video: [CMSampleBuffer]
    let systemAudio: [CMSampleBuffer]
    let microphone: [CMSampleBuffer]

    static let empty = ReplaySnapshot(video: [], systemAudio: [], microphone: [])
}

final class ReplayBuffer {
    private let lock = NSLock()
    private var video: [CMSampleBuffer] = []
    private var systemAudio: [CMSampleBuffer] = []
    private var microphone: [CMSampleBuffer] = []
    private var retention: CMTime
    private let audioSlack = CMTime(value: 1, timescale: 1)

    init(seconds: Int) {
        retention = CMTime(value: CMTimeValue(seconds), timescale: 1)
    }

    func setRetention(seconds: Int) {
        lock.withLock { retention = CMTime(value: CMTimeValue(seconds), timescale: 1) }
    }

    func reset() {
        lock.withLock {
            video.removeAll()
            systemAudio.removeAll()
            microphone.removeAll()
        }
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        lock.withLock {
            video.append(sample)
            pruneVideo()
        }
    }

    func appendAudio(_ sample: CMSampleBuffer, track: AudioTrack) {
        lock.withLock {
            switch track {
            case .system:
                systemAudio.append(sample)
                pruneAudio(&systemAudio)
            case .microphone:
                microphone.append(sample)
                pruneAudio(&microphone)
            }
        }
    }

    func snapshot() -> ReplaySnapshot {
        lock.withLock {
            guard let newest = video.last?.presentationTimeStamp else { return .empty }
            let startIndex = lastKeyFrameIndex(atOrBefore: newest - retention)
            let clip = Array(video[startIndex...])
            let start = clip[0].presentationTimeStamp
            let overlapsClip: (CMSampleBuffer) -> Bool = { sample in
                let end = sample.presentationTimeStamp + sample.duration
                return end >= start && sample.presentationTimeStamp <= newest
            }
            return ReplaySnapshot(
                video: clip,
                systemAudio: systemAudio.filter(overlapsClip),
                microphone: microphone.filter(overlapsClip)
            )
        }
    }

    private func lastKeyFrameIndex(atOrBefore cutoff: CMTime) -> Int {
        var found = 0
        for (index, sample) in video.enumerated() {
            if sample.presentationTimeStamp > cutoff { break }
            if sample.isKeyFrame { found = index }
        }
        return found
    }

    private func pruneVideo() {
        guard let newest = video.last?.presentationTimeStamp else { return }
        let dropCount = lastKeyFrameIndex(atOrBefore: newest - retention)
        if dropCount > 0 { video.removeFirst(dropCount) }
    }

    private func pruneAudio(_ samples: inout [CMSampleBuffer]) {
        guard let newest = samples.last?.presentationTimeStamp else { return }
        let cutoff = newest - retention - audioSlack
        let dropCount = samples.firstIndex { $0.presentationTimeStamp >= cutoff } ?? 0
        if dropCount > 0 { samples.removeFirst(dropCount) }
    }
}

extension CMSampleBuffer {
    var isKeyFrame: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    func deepCopiedAudio() -> CMSampleBuffer? {
        guard let source = dataBuffer, let format = formatDescription else { return nil }
        var copiedData: CMBlockBuffer?
        let copyStatus = CMBlockBufferCreateContiguous(
            allocator: kCFAllocatorDefault,
            sourceBuffer: source,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: 0,
            flags: kCMBlockBufferAlwaysCopyDataFlag,
            blockBufferOut: &copiedData
        )
        guard copyStatus == kCMBlockBufferNoErr, let copiedData else { return nil }
        var copy: CMSampleBuffer?
        let createStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: copiedData,
            formatDescription: format,
            sampleCount: numSamples,
            presentationTimeStamp: presentationTimeStamp,
            packetDescriptions: nil,
            sampleBufferOut: &copy
        )
        return createStatus == noErr ? copy : nil
    }
}
