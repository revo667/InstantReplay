import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = ReplayController()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAnotherInstanceRunning() {
            exit(0)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        let hostingController = NSHostingController(rootView: MenuView(controller: controller))
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController
        popover.behavior = .transient

        controller.$state
            .sink { [weak self] state in self?.updateIcon(for: state) }
            .store(in: &cancellables)

        controller.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stopForTermination()
    }

    private func isAnotherInstanceRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func updateIcon(for state: ReplayController.State) {
        let symbol: String
        switch state {
        case .off: symbol = "record.circle"
        case .starting: symbol = "hourglass.circle"
        case .recording: symbol = "record.circle.fill"
        case .saving: symbol = "arrow.down.circle.fill"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Instant Replay")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = state == .off
    }
}
