import AppKit
import Carbon.HIToolbox

enum ShortcutAction: CaseIterable, Identifiable {
    case saveReplay
    case toggleRecording

    var id: Self { self }

    var title: String {
        switch self {
        case .saveReplay: "Save shortcut"
        case .toggleRecording: "Record shortcut"
        }
    }

    var actionName: String {
        switch self {
        case .saveReplay: "saving replays"
        case .toggleRecording: "recording"
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .saveReplay: Shortcut(keyCode: kVK_F10, modifiers: optionKey)
        case .toggleRecording: Shortcut(keyCode: kVK_F9, modifiers: optionKey)
        }
    }

    fileprivate var keyCodeKey: String {
        switch self {
        case .saveReplay: Preferences.shortcutKeyCode
        case .toggleRecording: Preferences.recordShortcutKeyCode
        }
    }

    fileprivate var modifiersKey: String {
        switch self {
        case .saveReplay: Preferences.shortcutModifiers
        case .toggleRecording: Preferences.recordShortcutModifiers
        }
    }
}

struct Shortcut: Equatable {
    let keyCode: Int
    let modifiers: Int

    private static let functionKeyCodes: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let specialKeyLabels: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_Escape: "⎋", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_ANSI_KeypadEnter: "⌤",
    ]

    private static let modifierSymbols: [(mask: Int, symbol: String)] = [
        (controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘"),
    ]

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let keyCode = Int(event.keyCode)
        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        let isFunctionKey = Self.functionKeyCodes[keyCode] != nil
        let hasNonShiftModifier = modifiers & (cmdKey | optionKey | controlKey) != 0
        guard isFunctionKey || hasNonShiftModifier else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    var displayString: String {
        let modifierPrefix = Self.modifierSymbols
            .filter { modifiers & $0.mask != 0 }
            .map(\.symbol)
            .joined()
        return modifierPrefix + keyLabel
    }

    private var keyLabel: String {
        Self.functionKeyCodes[keyCode]
            ?? Self.specialKeyLabels[keyCode]
            ?? Self.layoutCharacter(for: keyCode)
            ?? "Key \(keyCode)"
    }

    static func load(for action: ShortcutAction) -> Shortcut {
        Shortcut(
            keyCode: Preferences.value(action.keyCodeKey, default: action.defaultShortcut.keyCode),
            modifiers: Preferences.value(action.modifiersKey, default: action.defaultShortcut.modifiers)
        )
    }

    func save(for action: ShortcutAction) {
        Preferences.set(keyCode, for: action.keyCodeKey)
        Preferences.set(modifiers, for: action.modifiersKey)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var result = 0
        if flags.contains(.command) { result |= cmdKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.shift) { result |= shiftKey }
        return result
    }

    private static func layoutCharacter(for keyCode: Int) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { buffer in
            UCKeyTranslate(
                buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let label = String(utf16CodeUnits: characters, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label.uppercased()
    }
}
