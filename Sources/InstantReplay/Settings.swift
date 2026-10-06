import AVFoundation
import CoreGraphics
import CoreMedia
import VideoToolbox

enum VideoQuality: String, CaseIterable, Identifiable {
    case p720
    case p1080
    case p1440
    case native

    var id: String { rawValue }

    var label: String {
        switch self {
        case .p720: "720p"
        case .p1080: "1080p"
        case .p1440: "1440p"
        case .native: "Native"
        }
    }

    var targetHeight: Int? {
        switch self {
        case .p720: 720
        case .p1080: 1080
        case .p1440: 1440
        case .native: nil
        }
    }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264
    case hevc
    case hevc10
    case prores422

    var id: String { rawValue }

    var label: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .hevc10: "HEVC 10-bit"
        case .prores422: "ProRes 422"
        }
    }

    var tier: String {
        switch self {
        case .h264: "Fastest"
        case .hevc: "Balanced"
        case .hevc10: "High Quality"
        case .prores422: "Best Quality"
        }
    }

    var codecType: CMVideoCodecType {
        switch self {
        case .h264: kCMVideoCodecType_H264
        case .hevc, .hevc10: kCMVideoCodecType_HEVC
        case .prores422: kCMVideoCodecType_AppleProRes422
        }
    }

    var profileLevel: CFString? {
        switch self {
        case .h264: kVTProfileLevel_H264_High_AutoLevel
        case .hevc: kVTProfileLevel_HEVC_Main_AutoLevel
        case .hevc10: kVTProfileLevel_HEVC_Main10_AutoLevel
        case .prores422: nil
        }
    }

    var capturePixelFormat: OSType {
        switch self {
        case .h264, .hevc: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .hevc10, .prores422: kCVPixelFormatType_32BGRA
        }
    }

    var usesBitRate: Bool { self != .prores422 }
    var isIntraOnly: Bool { self == .prores422 }
    var prefersRealTime: Bool { self == .h264 }

    var maxDimensions: (width: Int, height: Int)? {
        self == .h264 ? (4096, 2304) : nil
    }

    var fileType: AVFileType { self == .prores422 ? .mov : .mp4 }
    var fileExtension: String { self == .prores422 ? "mov" : "mp4" }
}

struct CaptureOptions {
    let quality: VideoQuality
    let codec: VideoCodec
    let frameRate: Int
    let bitRateMbps: Int
    let includeMicrophone: Bool
    let microphoneID: String?
}

struct AudioInput: Identifiable, Hashable {
    let id: String
    let name: String

    static func available() -> [AudioInput] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        .devices
        .map { AudioInput(id: $0.uniqueID, name: $0.localizedName) }
    }
}

enum Preferences {
    static let bufferSeconds = "bufferSeconds"
    static let quality = "quality"
    static let codec = "codec"
    static let frameRate = "frameRate"
    static let bitRateMbps = "bitRateMbpsV2"
    static let includesSystemAudio = "includesSystemAudio"
    static let systemVolume = "systemVolume"
    static let includesMicrophone = "capturesMicrophone"
    static let microphoneVolume = "microphoneVolume"
    static let microphoneID = "microphoneID"
    static let captureEnabled = "captureEnabled"
    static let didConfigureLaunchAtLogin = "didConfigureLaunchAtLogin"
    static let shortcutKeyCode = "shortcutKeyCode"
    static let shortcutModifiers = "shortcutModifiers"
    static let recordShortcutKeyCode = "recordShortcutKeyCode"
    static let recordShortcutModifiers = "recordShortcutModifiers"

    static func value<T>(_ key: String, default fallback: T) -> T {
        UserDefaults.standard.object(forKey: key) as? T ?? fallback
    }

    static func set(_ value: Any, for key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

enum Settings {
    static let durationOptions = [15, 30, 60, 120, 300]
    static let frameRateOptions = [30, 60, 120]
    static let bitRateRange: ClosedRange<Double> = 10...200
    static let defaultBitRateMbps = 50.0
    static let proResBitsPerPixel = 2.4

    static var outputDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let directory = movies.appendingPathComponent("InstantReplay", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func newClipURL(fileExtension: String) -> URL {
        outputDirectory.appendingPathComponent("Replay_\(timestamp()).\(fileExtension)")
    }

    static func newRecordingBaseName() -> String {
        let stem = "Recording_\(timestamp())"
        var candidate = stem
        var suffix = 2
        while FileManager.default.fileExists(atPath: recordingURL(baseName: candidate, part: 1).path) {
            candidate = "\(stem)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    static func recordingURL(baseName: String, part: Int) -> URL {
        let name = part > 1 ? "\(baseName)_part\(part)" : baseName
        return outputDirectory.appendingPathComponent("\(name).mov")
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }

    static func durationLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) seconds" }
        return seconds == 60 ? "1 minute" : "\(seconds / 60) minutes"
    }

    static func saveActionLabel(_ seconds: Int) -> String {
        "Save last \(durationLabel(seconds))"
    }

    static func mainDisplayPixelSize() -> (width: Int, height: Int) {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { return (1920, 1080) }
        return (mode.pixelWidth, mode.pixelHeight)
    }

    static func outputSize(native: (width: Int, height: Int), quality: VideoQuality, codec: VideoCodec) -> (width: Int, height: Int) {
        var scale = 1.0
        if let targetHeight = quality.targetHeight, targetHeight < native.height {
            scale = Double(targetHeight) / Double(native.height)
        }
        if let limit = codec.maxDimensions {
            scale = min(scale, Double(limit.width) / Double(native.width), Double(limit.height) / Double(native.height))
        }
        let width = Int((Double(native.width) * scale).rounded()) & ~1
        let height = Int((Double(native.height) * scale).rounded()) & ~1
        return (width, height)
    }
}
