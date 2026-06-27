import AppKit
import ApplicationServices
import AVFoundation
import Foundation

private enum Defaults {
    static let hotKey = "HotKey"
    static let enabled = "Enabled"
    static let apiKey = "WisprFlowAPIKey"
    static let dictationMode = "DictationMode"
}

private enum DictationMode: String {
    case api
    case hotKey

    static func load() -> DictationMode {
        guard let saved = UserDefaults.standard.string(forKey: Defaults.dictationMode),
              let mode = DictationMode(rawValue: saved) else {
            return .hotKey
        }
        return mode
    }

    var displayName: String {
        switch self {
        case .api:
            return "Wispr Flow API"
        case .hotKey:
            return "Hotkey Fallback"
        }
    }
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

private final class ClipboardPaster {
    func paste(_ text: String) {
        guard !text.isEmpty else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

private struct AudioPacket {
    let position: Int
    let wavBase64: String
    let volume: Double
    let duration: Double
}

private final class WAVEncoder {
    static func wavData(fromPCM16Mono pcmData: Data, sampleRate: Int = 16_000) -> Data {
        var data = Data()
        let byteRate = sampleRate * 2
        let blockAlign: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        let subchunk2Size = UInt32(pcmData.count)
        let chunkSize = UInt32(36 + pcmData.count)

        data.appendASCII("RIFF")
        data.appendLittleEndian(chunkSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(byteRate))
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(subchunk2Size)
        data.append(pcmData)
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(value.data(using: .ascii)!)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }
}

private final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var packetPosition = 0

    var onPacket: ((AudioPacket) -> Void)?
    var onError: ((String) -> Void)?

    func start() {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        packetPosition = 0

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            onError?("Could not start microphone capture: \(error.localizedDescription)")
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter else {
            return
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = max(AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32, 1)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return
        }

        var didProvideInput = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if didProvideInput {
                status.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            status.pointee = .haveData
            return buffer
        }

        if let conversionError {
            onError?("Could not convert microphone audio: \(conversionError.localizedDescription)")
            return
        }

        guard outputBuffer.frameLength > 0,
              let channelData = outputBuffer.int16ChannelData?[0] else {
            return
        }

        let sampleCount = Int(outputBuffer.frameLength)
        let pcmData = Data(bytes: channelData, count: sampleCount * MemoryLayout<Int16>.size)
        let volume = rmsVolume(samples: channelData, count: sampleCount)
        let duration = Double(outputBuffer.frameLength) / targetFormat.sampleRate
        let wavBase64 = WAVEncoder.wavData(fromPCM16Mono: pcmData).base64EncodedString()
        packetPosition += 1

        onPacket?(AudioPacket(position: packetPosition, wavBase64: wavBase64, volume: volume, duration: duration))
    }

    private func rmsVolume(samples: UnsafePointer<Int16>, count: Int) -> Double {
        guard count > 0 else {
            return 0
        }

        var sum = 0.0
        for index in 0..<count {
            let normalized = Double(samples[index]) / Double(Int16.max)
            sum += normalized * normalized
        }
        return sqrt(sum / Double(count))
    }
}

private final class WisprFlowAPIClient: NSObject, URLSessionWebSocketDelegate {
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let queue = DispatchQueue(label: "dev.local.wispr-flow-switch.api")
    private var pendingPackets: [AudioPacket] = []
    private var totalPackets = 0
    private var isAuthorized = false
    private var isClosing = false

    var onFinalText: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onError: ((String) -> Void)?

    func connect(apiKey: String) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            onError?("Wispr Flow API key is empty.")
            return
        }

        let encodedKey = trimmedKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmedKey
        guard let url = URL(string: "wss://platform-api.wisprflow.ai/api/v1/dash/ws?api_key=Bearer%20\(encodedKey)") else {
            onError?("Could not build Wispr Flow WebSocket URL.")
            return
        }

        queue.async {
            self.pendingPackets.removeAll()
            self.totalPackets = 0
            self.isAuthorized = false
            self.isClosing = false
        }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
        receiveNextMessage()
    }

    func append(_ packet: AudioPacket) {
        queue.async {
            self.totalPackets = max(self.totalPackets, packet.position)
            guard self.isAuthorized else {
                self.pendingPackets.append(packet)
                return
            }
            self.sendAppend(packet)
        }
    }

    func commitAndClose() {
        queue.async {
            self.isClosing = true
            let commit: [String: Any] = [
                "type": "commit",
                "total_packets": self.totalPackets
            ]
            self.sendJSON(commit) { [weak self] in
                self?.task?.cancel(with: .normalClosure, reason: nil)
                self?.session?.invalidateAndCancel()
            }
        }
    }

    func cancel() {
        queue.async {
            self.isClosing = true
            self.pendingPackets.removeAll()
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.session?.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocolName: String?) {
        let auth: [String: Any] = [
            "type": "auth",
            "context": "macOS menu bar dictation prototype",
            "language": ["pt", "en"]
        ]
        queue.async {
            self.sendJSON(auth)
        }
        DispatchQueue.main.async {
            self.onStatus?("API socket connected")
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async {
            self.onStatus?("API socket closed")
        }
    }

    private func receiveNextMessage() {
        task?.receive { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case .success(let message):
                self.handle(message)
                self.queue.async {
                    guard !self.isClosing else {
                        return
                    }
                    self.receiveNextMessage()
                }
            case .failure(let error):
                var shouldReport = true
                self.queue.sync {
                    shouldReport = !self.isClosing
                }
                guard shouldReport else {
                    return
                }
                DispatchQueue.main.async {
                    self.onError?("Wispr Flow WebSocket receive failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let messageData):
            data = messageData
        @unknown default:
            return
        }

        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let status = payload["status"] as? String
        switch status {
        case "auth":
            queue.async {
                self.isAuthorized = true
                let packets = self.pendingPackets
                self.pendingPackets.removeAll()
                packets.forEach(self.sendAppend)
            }
            DispatchQueue.main.async {
                self.onStatus?("API authenticated")
            }
        case "info":
            if let message = payload["message"] as? String {
                DispatchQueue.main.async {
                    self.onStatus?(message)
                }
            }
        case "text":
            guard let text = payload["text"] as? String else {
                return
            }
            let isFinal = (payload["final"] as? Bool) == true
                || (payload["is_final"] as? Bool) == true
                || (payload["complete"] as? Bool) == true
            if isFinal {
                DispatchQueue.main.async {
                    self.onFinalText?(text)
                }
            }
        case "error":
            let message = payload["message"] as? String ?? "Wispr Flow API returned an error."
            DispatchQueue.main.async {
                self.onError?(message)
            }
        default:
            break
        }
    }

    private func sendAppend(_ packet: AudioPacket) {
        let append: [String: Any] = [
            "type": "append",
            "audio_packets": [
                "packets": [packet.wavBase64],
                "volumes": [packet.volume],
                "packet_duration": packet.duration,
                "audio_encoding": "wav",
                "byte_encoding": "base64",
                "position": packet.position
            ]
        ]
        sendJSON(append)
    }

    private func sendJSON(_ object: [String: Any], completion: (() -> Void)? = nil) {
        guard let task else {
            DispatchQueue.main.async {
                self.onError?("Wispr Flow WebSocket is not connected.")
            }
            completion?()
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [])
            let text = String(decoding: data, as: UTF8.self)
            task.send(.string(text)) { [weak self] error in
                if let error {
                    DispatchQueue.main.async {
                        self?.onError?("Wispr Flow WebSocket send failed: \(error.localizedDescription)")
                    }
                }
                completion?()
            }
        } catch {
            DispatchQueue.main.async {
                self.onError?("Could not encode Wispr Flow WebSocket message: \(error.localizedDescription)")
            }
            completion?()
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let sender = HotKeySender()
    private let capture = MicrophoneCapture()
    private let apiClient = WisprFlowAPIClient()
    private let paster = ClipboardPaster()

    private var enabled = UserDefaults.standard.bool(forKey: Defaults.enabled)
    private var mode = DictationMode.load()
    private var hotKey = HotKey.load()
    private let toggleItem = NSMenuItem()
    private let modeItem = NSMenuItem()
    private let apiModeItem = NSMenuItem(title: "Wispr Flow API", action: #selector(selectAPIMode), keyEquivalent: "")
    private let hotKeyModeItem = NSMenuItem(title: "Hotkey Fallback", action: #selector(selectHotKeyMode), keyEquivalent: "")
    private let apiKeyItem = NSMenuItem(title: "Set API Key...", action: #selector(configureAPIKey), keyEquivalent: "")
    private let hotKeyItem = NSMenuItem()
    private let permissionsItem = NSMenuItem()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureCallbacks()
        configureMenu()
        updateMenu()
        requestAccessibilityPermissionIfNeeded()
    }

    private func configureCallbacks() {
        capture.onPacket = { [weak self] packet in
            self?.apiClient.append(packet)
        }
        capture.onError = { [weak self] message in
            DispatchQueue.main.async {
                self?.handleError(message)
            }
        }
        apiClient.onFinalText = { [weak self] text in
            self?.paster.paste(text)
        }
        apiClient.onStatus = { [weak self] _ in
            self?.updateMenu()
        }
        apiClient.onError = { [weak self] message in
            self?.handleError(message)
        }
    }

    private func configureMenu() {
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggleFromStatusButton)
        }

        toggleItem.target = self
        toggleItem.action = #selector(toggleDictation)
        menu.addItem(toggleItem)

        let modeMenu = NSMenu()
        apiModeItem.target = self
        hotKeyModeItem.target = self
        modeMenu.addItem(apiModeItem)
        modeMenu.addItem(hotKeyModeItem)
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        apiKeyItem.target = self
        menu.addItem(apiKeyItem)

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
        toggleItem.title = "Dictation: \(enabled ? "On" : "Off")"
        toggleItem.state = enabled ? .on : .off
        modeItem.title = "Mode: \(mode.displayName)"
        apiModeItem.state = mode == .api ? .on : .off
        hotKeyModeItem.state = mode == .hotKey ? .on : .off
        apiKeyItem.title = hasAPIKey ? "Change API Key..." : "Set API Key..."
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

    private var hasAPIKey: Bool {
        guard let apiKey = UserDefaults.standard.string(forKey: Defaults.apiKey) else {
            return false
        }
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func requestAccessibilityPermissionIfNeeded() {
        guard !AXIsProcessTrusted() else {
            return
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func toggleFromStatusButton() {
        toggleDictation()
    }

    @objc private func toggleDictation() {
        enabled.toggle()
        UserDefaults.standard.set(enabled, forKey: Defaults.enabled)

        switch mode {
        case .api:
            enabled ? startAPIDictation() : stopAPIDictation()
        case .hotKey:
            sender.send(hotKey)
        }
        updateMenu()
    }

    private func startAPIDictation() {
        guard let apiKey = UserDefaults.standard.string(forKey: Defaults.apiKey),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            enabled = false
            UserDefaults.standard.set(false, forKey: Defaults.enabled)
            showAPIKeyAlert()
            return
        }

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                guard granted else {
                    self.enabled = false
                    UserDefaults.standard.set(false, forKey: Defaults.enabled)
                    self.handleError("Microphone permission is required for Wispr Flow API mode.")
                    return
                }
                self.apiClient.connect(apiKey: apiKey)
                self.capture.start()
                self.updateMenu()
            }
        }
    }

    private func stopAPIDictation() {
        capture.stop()
        apiClient.commitAndClose()
    }

    @objc private func selectAPIMode() {
        setMode(.api)
    }

    @objc private func selectHotKeyMode() {
        setMode(.hotKey)
    }

    private func setMode(_ newMode: DictationMode) {
        guard newMode != mode else {
            return
        }

        if enabled, mode == .api {
            capture.stop()
            apiClient.cancel()
        }

        mode = newMode
        enabled = false
        UserDefaults.standard.set(mode.rawValue, forKey: Defaults.dictationMode)
        UserDefaults.standard.set(false, forKey: Defaults.enabled)
        updateMenu()
    }

    @objc private func configureAPIKey() {
        let alert = NSAlert()
        alert.messageText = "Configure Wispr Flow API Key"
        alert.informativeText = "Paste the API key from https://platform.wisprflow.ai. It is stored in local UserDefaults for this prototype."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.stringValue = UserDefaults.standard.string(forKey: Defaults.apiKey) ?? ""
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        UserDefaults.standard.set(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Defaults.apiKey)
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

    private func handleError(_ message: String) {
        enabled = false
        UserDefaults.standard.set(false, forKey: Defaults.enabled)
        capture.stop()
        apiClient.cancel()
        updateMenu()
        showAlert(title: "Wispr Flow Switch", message: message)
    }

    private func showAPIKeyAlert() {
        showAlert(title: "Wispr Flow API Key Required", message: "Set an API key before using Wispr Flow API mode.")
    }

    private func showInvalidHotKeyAlert() {
        showAlert(title: "Invalid Hotkey", message: "Use modifiers plus one key, for example: command+option+control+space")
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
