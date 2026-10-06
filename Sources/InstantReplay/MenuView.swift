import AppKit
import Carbon.HIToolbox
import SwiftUI

struct MenuView: View {
    @ObservedObject var controller: ReplayController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            saveSection
            Divider()
            videoSection
            Divider()
            audioSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text("Instant Replay").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Instant Replay", isOn: Binding(
                get: { controller.wantsCapture },
                set: { controller.setCaptureEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(controller.state == .starting)
        }
    }

    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                controller.saveReplay()
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.down")
                    Text(Settings.saveActionLabel(controller.bufferSeconds))
                    Spacer()
                    Text(controller.shortcut(for: .saveReplay).displayString).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(controller.state != .recording || !controller.wantsCapture)

            recordButton

            if let errorMessage = controller.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if controller.needsPermission {
                Button("Open Screen Recording settings") { controller.openPermissionSettings() }
                    .buttonStyle(.link)
            }
            if let lastClipURL = controller.lastClipURL {
                Button {
                    controller.revealLastClip()
                } label: {
                    Label(lastClipURL.lastPathComponent, systemImage: "film")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private var recordButton: some View {
        Button {
            controller.toggleRecording()
        } label: {
            HStack {
                Image(systemName: controller.isRecording ? "stop.fill" : "record.circle")
                if let startedAt = controller.recordingStartedAt {
                    Text("Stop recording")
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(elapsedText(since: startedAt, now: context.date))
                            .monospacedDigit()
                    }
                } else {
                    Text("Start recording")
                }
                Spacer()
                Text(controller.shortcut(for: .toggleRecording).displayString).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(controller.isRecording ? .red : nil)
        .disabled(controller.needsPermission || controller.state == .starting && !controller.isRecording)
    }

    private func elapsedText(since start: Date, now: Date) -> String {
        Duration.seconds(max(0, now.timeIntervalSince(start).rounded(.down)))
            .formatted(.time(pattern: .hourMinuteSecond))
    }

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Video")

            settingRow("Resolution") {
                Picker("Resolution", selection: $controller.quality) {
                    ForEach(VideoQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            settingRow("Frame rate") {
                Picker("Frame rate", selection: $controller.frameRate) {
                    ForEach(Settings.frameRateOptions, id: \.self) { fps in
                        Text("\(fps) fps").tag(fps)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            settingRow("Codec") {
                Picker("Codec", selection: $controller.codec) {
                    ForEach(VideoCodec.allCases) { codec in
                        Text("\(codec.label) · \(codec.tier)").tag(codec)
                    }
                }
                .labelsHidden()
            }

            settingRow("Length") {
                Picker("Length", selection: $controller.bufferSeconds) {
                    ForEach(Settings.durationOptions, id: \.self) { seconds in
                        Text(Settings.durationLabel(seconds)).tag(seconds)
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Bitrate")
                    Spacer()
                    Text(bitRateText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $controller.bitRateMbps, in: Settings.bitRateRange)
                    .disabled(!controller.codec.usesBitRate)
                Text(captureNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Audio")
            audioControl(
                title: "System audio",
                icon: "speaker.wave.2.fill",
                isOn: $controller.includesSystemAudio,
                volume: $controller.systemVolume,
                range: 0...1
            ) { EmptyView() }
            audioControl(
                title: "Microphone",
                icon: "mic.fill",
                isOn: $controller.includesMicrophone,
                volume: $controller.microphoneVolume,
                range: 0...2
            ) { microphonePicker }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ShortcutAction.allCases) { action in
                HStack {
                    Text(action.title)
                    Spacer()
                    ShortcutField(controller: controller, action: action)
                }
                if let shortcutError = controller.shortcutErrors[action] {
                    Text(shortcutError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle("Launch at login", isOn: Binding(
                get: { controller.launchAtLogin },
                set: { controller.setLaunchAtLogin($0) }
            ))
            if controller.launchAtLoginNeedsApproval {
                Button("Approve in Login Items") { controller.openLoginItemsSettings() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            HStack {
                Button("Open clips folder") { controller.openOutputDirectory() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
    }

    private var captureNote: String {
        let restartNote = controller.isRecording
            ? "Changing resolution, frame rate, codec or microphone starts a new part file."
            : "Changing resolution, frame rate, codec or microphone restarts the buffer."
        return "Uses ≈ \(controller.estimatedMemoryMB) MB of RAM. Recordings use ≈ \(controller.recordingMegabytesPerMinute) MB per minute of disk. \(restartNote)"
    }

    private var bitRateText: String {
        controller.codec.usesBitRate
            ? "\(controller.roundedBitRateMbps) Mbps"
            : "≈ \(Int(controller.effectiveBitRateMbps)) Mbps"
    }

    private var microphonePicker: some View {
        Menu {
            Picker("Input", selection: $controller.microphoneID) {
                Text("System Default").tag("")
                if !controller.microphoneID.isEmpty && controller.selectedMicrophone == nil {
                    Text("Disconnected device").tag(controller.microphoneID)
                }
                Divider()
                ForEach(controller.microphones) { input in
                    Text(input.name).tag(input.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "chevron.up.chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear { controller.refreshMicrophones() }
        .help("Input: \(controller.selectedMicrophone?.name ?? "System Default")")
    }

    private func audioControl<Accessory: View>(
        title: String,
        icon: String,
        isOn: Binding<Bool>,
        volume: Binding<Double>,
        range: ClosedRange<Double>,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Toggle(isOn: isOn) {
                    Label(title, systemImage: icon)
                }
                accessory()
                Spacer()
                Text("\(Int((volume.wrappedValue * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: volume, in: range)
                .disabled(!isOn.wrappedValue)
        }
    }

    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 76, alignment: .leading)
            content()
                .frame(maxWidth: .infinity)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var statusColor: Color {
        switch controller.state {
        case .off: .gray
        case .starting: .yellow
        case .recording: .red
        case .saving: .blue
        }
    }

    private var statusText: String {
        switch controller.state {
        case .off: "Off"
        case .starting: "Starting…"
        case .recording where !controller.wantsCapture: "Replay off · Recording to disk"
        case .recording: "Recording · \(controller.quality.label) · \(controller.frameRate) fps · \(controller.codec.label)"
        case .saving: "Saving clip…"
        }
    }
}

struct ShortcutField: View {
    @ObservedObject var controller: ReplayController
    let action: ShortcutAction
    @StateObject private var monitor = KeyDownMonitor()

    private var isEditing: Bool {
        controller.editingShortcut == action
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                isEditing ? cancelEditing() : startEditing()
            } label: {
                Text(isEditing ? "Press keys…" : controller.shortcut(for: action).displayString)
                    .monospacedDigit()
                    .frame(minWidth: 90)
            }
            .help(isEditing ? "Press a new shortcut, or Esc to cancel" : "Click to change the shortcut")

            if !isEditing && controller.shortcut(for: action) != action.defaultShortcut {
                Button {
                    controller.resetShortcut(for: action)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Reset to \(action.defaultShortcut.displayString)")
            }
        }
        .onChange(of: controller.editingShortcut) { _, editing in
            if editing != action { monitor.stop() }
        }
        .onDisappear(perform: cancelEditing)
    }

    private func startEditing() {
        controller.beginShortcutEditing(action)
        monitor.start { event in
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func cancelEditing() {
        monitor.stop()
        if isEditing { controller.cancelShortcutEditing() }
    }

    private func handle(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if Int(event.keyCode) == kVK_Escape && modifiers.isEmpty {
            cancelEditing()
            return
        }
        guard let shortcut = Shortcut(event: event) else {
            NSSound.beep()
            return
        }
        monitor.stop()
        controller.applyShortcut(shortcut, for: action)
    }
}

final class KeyDownMonitor: ObservableObject {
    private var token: Any?

    func start(handler: @escaping (NSEvent) -> NSEvent?) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
    }

    func stop() {
        guard let token else { return }
        NSEvent.removeMonitor(token)
        self.token = nil
    }

    deinit {
        stop()
    }
}
