import AppKit
import ApplicationServices

private enum Defaults {
    static let hotKey = "HotKey"
    static let enabled = "Enabled"
}

private struct HotKey {
    let keyCode: CGKeyCode
    let modifiers: CGEventFlags
    let displayName: String

    static let defaultString = "command+option+control+space"

    static func load() -> HotKey {
        let saved = UserDefaults.standard.string(forKey: Defaults.hotKey) ?? defaultString
        return parse(saved) ?? parse(defaultString)!
    }

    static func parse(_ value: String) -> HotKey? {
        let parts = value
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .split(separator: "+")
            .map(String.init)

        guard let keyName = parts.last, let keyCode = keyCodes[keyName] else {
            return nil
        }

        var flags = CGEventFlags()
        var modifierNames: [String] = []

        for part in parts.dropLast() {
            switch part {
            case "command", "cmd", "meta":
                flags.insert(.maskCommand)
                modifierNames.append("command")
            case "option", "opt", "alt":
                flags.insert(.maskAlternate)
                modifierNames.append("option")
            case "control", "ctrl":
                flags.insert(.maskControl)
                modifierNames.append("control")
            case "shift":
                flags.insert(.maskShift)
                modifierNames.append("shift")
            default:
                return nil
            }
        }

        let displayName = (modifierNames + [keyName]).joined(separator: "+")
        return HotKey(keyCode: keyCode, modifiers: flags, displayName: displayName)
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "escape": 53, "esc": 53,
        "delete": 51, "backspace": 51,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]
}

private final class HotKeySender {
    func send(_ hotKey: HotKey) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: hotKey.keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: hotKey.keyCode, keyDown: false) else {
            return
        }

        keyDown.flags = hotKey.modifiers
        keyUp.flags = hotKey.modifiers
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let sender = HotKeySender()

    private var enabled = UserDefaults.standard.bool(forKey: Defaults.enabled)
    private var hotKey = HotKey.load()
    private let toggleItem = NSMenuItem()
    private let hotKeyItem = NSMenuItem()
    private let permissionsItem = NSMenuItem()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        updateMenu()
        requestAccessibilityPermissionIfNeeded()
    }

    private func configureMenu() {
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggleFromStatusButton)
        }

        toggleItem.target = self
        toggleItem.action = #selector(toggleDictation)
        menu.addItem(toggleItem)

        hotKeyItem.isEnabled = false
        menu.addItem(hotKeyItem)

        let configureItem = NSMenuItem(
            title: "Configure Hotkey...",
            action: #selector(configureHotKey),
            keyEquivalent: ""
        )
        configureItem.target = self
        menu.addItem(configureItem)

        permissionsItem.target = self
        permissionsItem.action = #selector(openAccessibilitySettings)
        menu.addItem(permissionsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateMenu() {
        toggleItem.title = "Hands-free Dictation: \(enabled ? "On" : "Off")"
        toggleItem.state = enabled ? .on : .off
        hotKeyItem.title = "Hotkey: \(hotKey.displayName)"

        if AXIsProcessTrusted() {
            permissionsItem.title = "Accessibility Permission: Granted"
            permissionsItem.isEnabled = false
        } else {
            permissionsItem.title = "Open Accessibility Settings..."
            permissionsItem.isEnabled = true
        }

        if let button = statusItem.button {
            button.title = enabled ? "Flow On" : "Flow Off"
        }
    }

    private func requestAccessibilityPermissionIfNeeded() {
        guard !AXIsProcessTrusted() else {
            return
        }

        let options = [kAXTrustedCheckOptionPrompt as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func toggleFromStatusButton() {
        toggleDictation()
    }

    @objc private func toggleDictation() {
        enabled.toggle()
        UserDefaults.standard.set(enabled, forKey: Defaults.enabled)
        sender.send(hotKey)
        updateMenu()
    }

    @objc private func configureHotKey() {
        let alert = NSAlert()
        alert.messageText = "Configure Wispr Flow Hotkey"
        alert.informativeText = "Use plus-separated keys, for example: command+option+control+space"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.stringValue = UserDefaults.standard.string(forKey: Defaults.hotKey) ?? HotKey.defaultString
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        guard let parsed = HotKey.parse(input.stringValue) else {
            showInvalidHotKeyAlert()
            return
        }

        hotKey = parsed
        UserDefaults.standard.set(parsed.displayName, forKey: Defaults.hotKey)
        updateMenu()
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private func showInvalidHotKeyAlert() {
        let alert = NSAlert()
        alert.messageText = "Invalid Hotkey"
        alert.informativeText = "Use modifiers plus one key, for example: command+option+control+space"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
