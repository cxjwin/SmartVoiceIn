import Cocoa

final class HotKeyManager {

    static let defaultShortcutKeyCodes: [UInt16] = [54]  // 右 Command
    private static let shortcutKeyCodesDefaultsKey = "voiceinput.hotkey.keycodes"
    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let callback: () -> Void

    private var pressedKeyCodes = Set<UInt16>()
    private var shortcutKeyCodes = Set(defaultShortcutKeyCodes)
    private var isShortcutActive = false
    private var isEnabled = true

    init(callback: @escaping () -> Void) {
        self.callback = callback
        if let persisted = Self.loadPersistedShortcutKeyCodes() {
            shortcutKeyCodes = Set(persisted)
        }
        checkAccessibility()
        registerHotKey()
        print("[HotKey] 当前快捷键: \(currentShortcutDisplayName())")
    }

    deinit {
        unregisterHotKey()
    }

    func currentShortcutDisplayName() -> String {
        return Self.formatShortcutDisplayName(keyCodes: currentShortcutKeyCodes())
    }

    func currentShortcutKeyCodes() -> [UInt16] {
        return Self.normalizedShortcutKeyCodes(Array(shortcutKeyCodes))
    }

    @discardableResult
    func updateShortcut(keyCodes: [UInt16]) -> Bool {
        guard Self.isValidShortcutKeyCodes(keyCodes) else {
            return false
        }
        let normalized = Self.normalizedShortcutKeyCodes(keyCodes)
        shortcutKeyCodes = Set(normalized)
        pressedKeyCodes.removeAll()
        isShortcutActive = false
        persistShortcutKeyCodes(normalized)
        print("[HotKey] 快捷键已更新: \(Self.formatShortcutDisplayName(keyCodes: normalized))")
        return true
    }

    func resetToDefaultShortcut() {
        _ = updateShortcut(keyCodes: Self.defaultShortcutKeyCodes)
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else {
            return
        }
        isEnabled = enabled
        pressedKeyCodes.removeAll()
        isShortcutActive = false
        print("[HotKey] 监听状态: \(enabled ? "开启" : "暂停")")
    }

    static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        return modifierKeyCodes.contains(keyCode)
    }

    static func normalizedShortcutKeyCodes(_ keyCodes: [UInt16]) -> [UInt16] {
        let unique = Set(keyCodes)
        return unique.sorted { lhs, rhs in
            sortPriority(for: lhs) < sortPriority(for: rhs)
        }
    }

    static func formatShortcutDisplayName(keyCodes: [UInt16]) -> String {
        let normalized = normalizedShortcutKeyCodes(keyCodes)
        if normalized.isEmpty {
            return "未设置"
        }
        return normalized.map { displayName(forKeyCode: $0) }.joined(separator: " + ")
    }

    private static func isValidShortcutKeyCodes(_ keyCodes: [UInt16]) -> Bool {
        let uniqueCount = Set(keyCodes).count
        return (1...2).contains(uniqueCount)
    }

    private static func sortPriority(for keyCode: UInt16) -> Int {
        let modifierOrder: [UInt16] = [59, 62, 58, 61, 56, 60, 55, 54, 57, 63]
        if let index = modifierOrder.firstIndex(of: keyCode) {
            return index
        }
        return 1000 + Int(keyCode)
    }

    private static func displayName(forKeyCode keyCode: UInt16) -> String {
        switch keyCode {
        case 54: return "右 Command"
        case 55: return "左 Command"
        case 56: return "左 Shift"
        case 57: return "Caps Lock"
        case 58: return "左 Option"
        case 59: return "左 Control"
        case 60: return "右 Shift"
        case 61: return "右 Option"
        case 62: return "右 Control"
        case 63: return "Fn"
        default:
            return keyCodeNameMap[keyCode] ?? "KeyCode \(keyCode)"
        }
    }

    private static let keyCodeNameMap: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
        64: "F17", 65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Keypad Clear",
        75: "Keypad /", 76: "Keypad Enter", 78: "Keypad -",
        79: "F18", 80: "F19", 81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4",
        87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 90: "F20", 91: "Keypad 8", 92: "Keypad 9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1",
        123: "Left Arrow", 124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow"
    ]

    private static func loadPersistedShortcutKeyCodes() -> [UInt16]? {
        guard let rawValue = UserDefaults.standard.string(forKey: shortcutKeyCodesDefaultsKey),
              !rawValue.isEmpty else {
            return nil
        }
        let parsed = rawValue
            .split(separator: ",")
            .compactMap { UInt16($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard isValidShortcutKeyCodes(parsed) else {
            return nil
        }
        return normalizedShortcutKeyCodes(parsed)
    }

    private func persistShortcutKeyCodes(_ keyCodes: [UInt16]) {
        let serialized = keyCodes.map(String.init).joined(separator: ",")
        UserDefaults.standard.set(serialized, forKey: Self.shortcutKeyCodesDefaultsKey)
    }

    private func checkAccessibility() {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            print("[HotKey] 需要辅助功能权限")
        } else {
            print("[HotKey] 辅助功能权限已授予")
        }
    }

    private func registerHotKey() {
        let eventMask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handleEvent(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handleEvent(event)
            return event
        }

        print("[HotKey] 监听快捷键事件（支持 1~2 键组合）")
    }

    private func handleEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if event.isARepeat {
                return
            }
            pressedKeyCodes.insert(event.keyCode)
            evaluateShortcutState()
        case .keyUp:
            pressedKeyCodes.remove(event.keyCode)
            evaluateShortcutState()
        case .flagsChanged:
            handleModifierFlagsChanged(event)
        default:
            break
        }
    }

    private func handleModifierFlagsChanged(_ event: NSEvent) {
        let keyCode = event.keyCode
        guard Self.isModifierKeyCode(keyCode) else {
            return
        }
        togglePressedModifierKey(keyCode)
        evaluateShortcutState()
    }

    private func togglePressedModifierKey(_ keyCode: UInt16) {
        if pressedKeyCodes.contains(keyCode) {
            pressedKeyCodes.remove(keyCode)
        } else {
            pressedKeyCodes.insert(keyCode)
        }
    }

    private func evaluateShortcutState() {
        guard isEnabled else {
            return
        }

        let isMatch = pressedKeyCodes == shortcutKeyCodes

        if isMatch && !isShortcutActive {
            isShortcutActive = true
            print("[HotKey] 快捷键触发: \(currentShortcutDisplayName())")
            callback()
            return
        }

        if !isMatch {
            isShortcutActive = false
        }
    }

    private func unregisterHotKey() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }
}
