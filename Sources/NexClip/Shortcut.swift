// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Carbon

/// Physical key code + Carbon modifiers. The legacy preference keys remain unchanged.
struct ShortcutConfiguration: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    static let modifierMask = UInt32(controlKey | optionKey | shiftKey | cmdKey)
    static let presets: [ShortcutConfiguration] = [
        .init(keyCode: 50, modifiers: UInt32(controlKey | optionKey)),
        .init(keyCode: 49, modifiers: UInt32(controlKey | optionKey)),
        .init(keyCode: 9, modifiers: UInt32(controlKey | shiftKey))
    ]
    static let initial = presets[0]

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        for (flag, carbon) in [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey),
                               (.shift, shiftKey), (.command, cmdKey)] {
            if flags.contains(flag) { result |= UInt32(carbon) }
        }
        return result
    }
    var isValid: Bool {
        // Reject modifier-only key codes, Caps Lock/Fn alone, and unsupported Carbon bits.
        keyCode <= 127 && ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode)
            && modifiers & Self.modifierMask != 0 && modifiers & ~Self.modifierMask == 0
    }
    func validate() throws {
        guard isValid else { throw LocalError("El atajo necesita una tecla y al menos un modificador: ⌃, ⌥, ⇧ o ⌘.") }
    }
    static func load(from defaults: UserDefaults) -> ShortcutConfiguration {
        guard let key = UInt32(exactly: defaults.integer(forKey: "hotKey")),
              let modifiers = UInt32(exactly: defaults.integer(forKey: "hotModifiers")) else { return .initial }
        let value = ShortcutConfiguration(keyCode: key, modifiers: modifiers)
        return value.isValid ? value : .initial
    }
    func persist(in defaults: UserDefaults) throws {
        try validate()
        defaults.set(Int(keyCode), forKey: "hotKey")
        defaults.set(Int(modifiers), forKey: "hotModifiers")
    }
    var description: String {
        var symbols = ""
        for (mask, symbol) in [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")] {
            if modifiers & UInt32(mask) != 0 { symbols += symbol }
        }
        return symbols + " " + Self.keyName(keyCode)
    }
    /// Stable ANSI physical-key labels, deliberately independent of session/keyboard layout.
    static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
            0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V",
            11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2", 20:"3",
            21:"4", 22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"−", 28:"8", 29:"0", 30:"]",
            31:"O", 32:"U", 33:"[", 34:"I", 35:"P", 36:"Retorno", 37:"L", 38:"J", 39:"'", 40:"K",
            41:";", 42:"\\", 43:",", 44:"/", 45:"N", 46:"M", 47:".", 48:"Tab", 49:"Espacio",
            50:"`", 51:"⌫", 53:"Esc", 64:"F17", 65:"Decimal numérico", 67:"× numérico", 69:"+ numérico",
            71:"Borrar numérico", 75:"÷ numérico", 76:"Intro numérico", 78:"− numérico", 79:"F18", 80:"F19",
            81:"= numérico", 82:"0 numérico", 83:"1 numérico", 84:"2 numérico", 85:"3 numérico", 86:"4 numérico",
            87:"5 numérico", 88:"6 numérico", 89:"7 numérico", 90:"F20", 91:"8 numérico", 92:"9 numérico",
            96:"F5", 97:"F6", 98:"F7", 99:"F3", 100:"F8", 101:"F9", 103:"F11", 105:"F13", 106:"F16",
            107:"F14", 109:"F10", 111:"F12", 113:"F15", 114:"Ayuda", 115:"Inicio", 116:"Página ↑",
            117:"⌦", 118:"F4", 119:"Fin", 120:"F2", 121:"Página ↓", 122:"F1", 123:"←", 124:"→", 125:"↓", 126:"↑"
        ]
        return names[code] ?? "Tecla física \(code)"
    }
}

/// Register first, release the previous handle only after success. Also testable without Carbon/UI.
final class ShortcutRegistration<Handle> {
    private(set) var configuration: ShortcutConfiguration?
    private var handle: Handle?
    private let acquire: (ShortcutConfiguration) throws -> Handle
    private let release: (Handle) -> Void
    init(acquire: @escaping (ShortcutConfiguration) throws -> Handle, release: @escaping (Handle) -> Void) {
        self.acquire = acquire; self.release = release
    }
    func replace(with candidate: ShortcutConfiguration) throws {
        try candidate.validate()
        guard configuration != candidate else { return }
        let next = try acquire(candidate)
        let previous = handle
        handle = next; configuration = candidate
        if let previous { release(previous) }
    }
    deinit { if let handle { release(handle) } }
}

/// Only receives events sent to this first responder; never installs a global keyboard monitor.
final class ShortcutRecorder: NSButton {
    var onRecorded: ((ShortcutConfiguration) -> Void)?
    var onMessage: ((String) -> Void)?
    private(set) var isRecording = false
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = "Grabar atajo"; bezelStyle = .rounded
        target = self; action = #selector(startRecording)
        setAccessibilityLabel("Grabar atajo personalizado")
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    @objc private func startRecording() {
        guard window?.makeFirstResponder(self) == true else { return }
        isRecording = true; title = "Pulsa el atajo… (Esc cancela)"
        onMessage?("Pulsa una tecla con ⌃, ⌥, ⇧ o ⌘. Esc cancela.")
    }
    func cancelRecording() { isRecording = false; title = "Grabar atajo" }
    override func resignFirstResponder() -> Bool { cancelRecording(); return super.resignFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.isKeyWindow == true else { return super.performKeyEquivalent(with: event) }
        receive(event); return true
    }
    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        receive(event)
    }
    private func receive(_ event: NSEvent) {
        if event.keyCode == 53 { cancelRecording(); onMessage?("Grabación cancelada; no se cambió el atajo."); return }
        let value = ShortcutConfiguration(keyCode: UInt32(event.keyCode), modifiers: ShortcutConfiguration.carbonModifiers(from: event.modifierFlags))
        guard value.isValid else { onMessage?("Añade al menos un modificador: ⌃, ⌥, ⇧ o ⌘. Esc cancela."); return }
        cancelRecording(); onRecorded?(value)
    }
}
