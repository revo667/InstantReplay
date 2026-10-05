import AppKit
import CoreGraphics
import ServiceManagement

@MainActor
final class ReplayController: ObservableObject {
    enum State {
        case off
        case starting
        case recording
        case saving
    }

    @Published private(set) var state = State.off
    @Published private(set) var wantsCapture = false
    @Published private(set) var lastClipURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var needsPermission = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginNeedsApproval = false

    @Published var bufferSeconds: Int {
        didSet {
            Preferences.set(bufferSeconds, for: Preferences.bufferSeconds)
            buffer.setRetention(seconds: bufferSeconds)
        }
    }

    @Published var quality: VideoQuality {
        didSet {
            guard quality != oldValue else { return }
            Preferences.set(quality.rawValue, for: Preferences.quality)
            restartIfRunning()
        }
    }

    @Published var codec: VideoCodec {
        didSet {
            guard codec != oldValue else { return }
            Preferences.set(codec.rawValue, for: Preferences.codec)
            restartIfRunning()
        }
    }

    @Published var frameRate: Int {
        didSet {
            guard frameRate != oldValue else { return }
            Preferences.set(frameRate, for: Preferences.frameRate)
            restartIfRunning()
        }
    }

    @Published var bitRateMbps: Double {
        didSet {
            Preferences.set(bitRateMbps, for: Preferences.bitRateMbps)
            engine.updateBitRate(mbps: roundedBitRateMbps)
        }
    }

    @Published var includesSystemAudio: Bool {
        didSet { Preferences.set(includesSystemAudio, for: Preferences.includesSystemAudio) }
    }

    @Published var systemVolume: Double {
        didSet { Preferences.set(systemVolume, for: Preferences.systemVolume) }
    }

    @Published var includesMicrophone: Bool {
        didSet {
            guard includesMicrophone != oldValue else { return }
            Preferences.set(includesMicrophone, for: Preferences.includesMicrophone)
            restartIfRunning()
        }
    }

    @Published var microphoneVolume: Double {
        didSet { Preferences.set(microphoneVolume, for: Preferences.microphoneVolume) }
    }

    private let buffer: ReplayBuffer
    private let engine: CaptureEngine
    private let loginAgent = SMAppService.agent(plistName: "com.yildiz.InstantReplay.agent.plist")
    private var operation: Task<Void, Never>?
    private var isOperationRunning = false
    private var didRequestPermission = false
    private var watchdog: Timer?
    private var backgroundActivity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    private var activeCodec = VideoCodec.hevc

    init() {
        let storedSeconds: Int = Preferences.value(Preferences.bufferSeconds, default: 30)
        bufferSeconds = storedSeconds
        quality = VideoQuality(rawValue: Preferences.value(Preferences.quality, default: VideoQuality.p1080.rawValue)) ?? .p1080
        codec = VideoCodec(rawValue: Preferences.value(Preferences.codec, default: VideoCodec.hevc.rawValue)) ?? .hevc
        frameRate = Preferences.value(Preferences.frameRate, default: 60)
        bitRateMbps = Preferences.value(Preferences.bitRateMbps, default: Settings.defaultBitRateMbps)
        includesSystemAudio = Preferences.value(Preferences.includesSystemAudio, default: true)
        systemVolume = Preferences.value(Preferences.systemVolume, default: 1)
        includesMicrophone = Preferences.value(Preferences.includesMicrophone, default: false)
        microphoneVolume = Preferences.value(Preferences.microphoneVolume, default: 1)

        buffer = ReplayBuffer(seconds: storedSeconds)
        engine = CaptureEngine(buffer: buffer)
        engine.onUnexpectedStop = { [weak self] _ in
            Task { @MainActor in self?.recoverFromStop() }
        }
        refreshLaunchAtLoginStatus()
    }

    func launch() {
        configureLaunchAtLoginOnFirstRun()
        observeSystemEvents()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ensureCaptureAlive() }
        }
        if Preferences.value(Preferences.captureEnabled, default: true) {
            start()
        }
    }

    var roundedBitRateMbps: Int {
        Int((bitRateMbps / 5).rounded() * 5)
    }

    var estimatedMemoryMB: Int {
        Int(effectiveBitRateMbps * Double(bufferSeconds + 1) / 8)
    }

    var effectiveBitRateMbps: Double {
        guard !codec.usesBitRate else { return Double(roundedBitRateMbps) }
        let size = Settings.outputSize(native: Settings.mainDisplayPixelSize(), quality: quality, codec: codec)
        return Double(size.width * size.height * frameRate) * Settings.proResBitsPerPixel / 1_000_000
    }

    func setCaptureEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    func start() {
        wantsCapture = true
        Preferences.set(true, for: Preferences.captureEnabled)
        enqueue { [weak self] in await self?.performStart() }
    }

    func stop() {
        wantsCapture = false
        Preferences.set(false, for: Preferences.captureEnabled)
        enqueue { [weak self] in await self?.performStop() }
    }

    func saveReplay() {
        guard state == .recording else {
            NSSound.beep()
            return
        }
        state = .saving
        let snapshot = buffer.snapshot()
        let mix = ClipAudioMix(
            systemGain: includesSystemAudio ? Float(systemVolume) : nil,
            microphoneGain: includesMicrophone ? Float(microphoneVolume) : nil
        )
        let clipCodec = activeCodec
        let url = Settings.newClipURL(fileExtension: clipCodec.fileExtension)
        Task {
            do {
                try await ClipWriter.write(snapshot, mix: mix, fileType: clipCodec.fileType, to: url)
                lastClipURL = url
                errorMessage = nil
                NSSound(named: "Glass")?.play()
            } catch {
                errorMessage = "Save failed: \(error.localizedDescription)"
                NSSound(named: "Basso")?.play()
            }
            if state == .saving { state = engine.isRunning ? .recording : .off }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try loginAgent.register()
            } else {
                try loginAgent.unregister()
            }
        } catch {
            errorMessage = "Could not change Launch at Login: \(error.localizedDescription)"
        }
        refreshLaunchAtLoginStatus()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func revealLastClip() {
        guard let lastClipURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastClipURL])
    }

    func openOutputDirectory() {
        NSWorkspace.shared.open(Settings.outputDirectory)
    }

    func openPermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func stopForTermination() {
        let engine = engine
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await engine.stop()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    private var currentOptions: CaptureOptions {
        CaptureOptions(
            quality: quality,
            codec: codec,
            frameRate: frameRate,
            bitRateMbps: roundedBitRateMbps,
            includeMicrophone: includesMicrophone
        )
    }

    private func restartIfRunning() {
        guard wantsCapture else { return }
        start()
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = operation
        operation = Task {
            await previous?.value
            isOperationRunning = true
            await work()
            isOperationRunning = false
        }
    }

    private func performStart() async {
        guard wantsCapture else { return }
        if !CGPreflightScreenCaptureAccess() && !didRequestPermission {
            didRequestPermission = true
            CGRequestScreenCaptureAccess()
        }
        state = .starting
        do {
            let options = currentOptions
            try await engine.start(options: options)
            activeCodec = options.codec
            state = .recording
            needsPermission = false
            errorMessage = nil
            beginBackgroundActivity()
        } catch {
            state = .off
            needsPermission = !CGPreflightScreenCaptureAccess()
            errorMessage = needsPermission
                ? "Screen Recording permission is missing. Grant it, then relaunch Instant Replay."
                : "Could not start, retrying: \(error.localizedDescription)"
        }
    }

    private func performStop() async {
        await engine.stop()
        buffer.reset()
        state = .off
        endBackgroundActivity()
    }

    private func ensureCaptureAlive() {
        guard wantsCapture, !needsPermission, !isOperationRunning else { return }
        guard state == .off || !engine.isRunning else { return }
        guard state != .saving else { return }
        enqueue { [weak self] in await self?.performStart() }
    }

    private func restartIfDisplayChanged() {
        guard wantsCapture, let displayID = engine.displayID else { return }
        let activeDisplays = activeDisplayIDs()
        guard displayID != CGMainDisplayID() || !activeDisplays.contains(displayID) else { return }
        enqueue { [weak self] in await self?.performStart() }
    }

    private func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        return displays
    }

    private func observeSystemEvents() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let wakeEvents: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for name in wakeEvents {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    self?.ensureCaptureAlive()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartIfDisplayChanged() }
        })
    }

    private func beginBackgroundActivity() {
        guard backgroundActivity == nil else { return }
        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Instant Replay buffer capture"
        )
    }

    private func endBackgroundActivity() {
        guard let backgroundActivity else { return }
        ProcessInfo.processInfo.endActivity(backgroundActivity)
        self.backgroundActivity = nil
    }

    private func configureLaunchAtLoginOnFirstRun() {
        guard !Preferences.value(Preferences.didConfigureLaunchAtLogin, default: false) else { return }
        Preferences.set(true, for: Preferences.didConfigureLaunchAtLogin)
        if loginAgent.status != .enabled {
            try? loginAgent.register()
        }
        refreshLaunchAtLoginStatus()
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLogin = loginAgent.status == .enabled
        launchAtLoginNeedsApproval = loginAgent.status == .requiresApproval
    }

    private func recoverFromStop() {
        state = .off
        endBackgroundActivity()
        guard wantsCapture else { return }
        enqueue { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.wantsCapture, !self.engine.isRunning else { return }
            await self.performStart()
        }
    }
}
