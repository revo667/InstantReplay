import CoreMedia
import VideoToolbox

enum VideoEncoderError: LocalizedError {
    case creationFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .creationFailed(let codec, let status): "Could not create the \(codec) encoder (OSStatus \(status))."
        }
    }
}

final class VideoEncoder {
    private var session: VTCompressionSession?
    private let codec: VideoCodec
    private let onEncoded: (CMSampleBuffer) -> Void
    private let keyFrameInterval = CMTime(value: 1, timescale: 1)
    private let fallbackFrameDuration: CMTime
    private var lastKeyFrameTime = CMTime.invalid

    init(
        codec: VideoCodec,
        width: Int,
        height: Int,
        frameRate: Int,
        bitRate: Int,
        onEncoded: @escaping (CMSampleBuffer) -> Void
    ) throws {
        self.codec = codec
        self.onEncoded = onEncoded
        fallbackFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        var created: VTCompressionSession?
        let specification = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec.codecType,
            encoderSpecification: specification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else { throw VideoEncoderError.creationFailed(codec.label, status) }
        session = created

        var properties: [CFString: CFTypeRef] = [
            kVTCompressionPropertyKey_RealTime: codec.prefersRealTime ? kCFBooleanTrue : kCFBooleanFalse,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: codec.prefersRealTime ? kCFBooleanTrue : kCFBooleanFalse,
            kVTCompressionPropertyKey_ExpectedFrameRate: frameRate as CFNumber,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        if let profileLevel = codec.profileLevel {
            properties[kVTCompressionPropertyKey_ProfileLevel] = profileLevel
        }
        if !codec.isIntraOnly {
            properties[kVTCompressionPropertyKey_AllowFrameReordering] = kCFBooleanFalse
            properties[kVTCompressionPropertyKey_MaxKeyFrameInterval] = frameRate as CFNumber
            properties[kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration] = 1 as CFNumber
        }
        if codec == .h264 {
            properties[kVTCompressionPropertyKey_H264EntropyMode] = kVTH264EntropyMode_CABAC
        }
        for (key, value) in properties {
            VTSessionSetProperty(created, key: key, value: value)
        }
        setBitRate(bitRate)
        VTCompressionSessionPrepareToEncodeFrames(created)
    }

    func setBitRate(_ bitRate: Int) {
        guard let session, codec.usesBitRate else { return }
        let peakBytesPerSecond = bitRate * 2 / 8
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [peakBytesPerSecond, 1] as CFArray)
    }

    func encode(_ pixelBuffer: CVPixelBuffer, at time: CMTime, duration: CMTime) {
        guard let session else { return }
        var frameProperties: CFDictionary?
        if !codec.isIntraOnly, !lastKeyFrameTime.isValid || time - lastKeyFrameTime >= keyFrameInterval {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            lastKeyFrameTime = time
        }
        let frameDuration = duration.isValid ? duration : fallbackFrameDuration
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: time,
            duration: frameDuration,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [onEncoded] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            onEncoded(sampleBuffer)
        }
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }
}
