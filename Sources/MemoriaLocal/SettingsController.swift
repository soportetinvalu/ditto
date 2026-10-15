// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Carbon
import ServiceManagement

private final class SettingsDocumentView: NSView { override var isFlipped: Bool { true } }

final class SettingsController: NSObject, NSWindowDelegate {
    let preferences: Preferences
    let store: ClipStore
    var onSave: (() throws -> Void)?
    var onShortcutSave: ((ShortcutConfiguration) throws -> Void)?
    private let recorder = ShortcutRecorder(frame: .zero)
    private let shortcutValue = NSTextField(labelWithString: "")
    private let shortcutMessage = NSTextField(wrappingLabelWithString: "")
    private var pendingShortcut = ShortcutConfiguration.initial
    private var window: NSWindow!
    private let capture = NSButton(checkboxWithTitle: "Capturar nuevas copias (consentimiento local)", target: nil, action: nil)
    private let autoPaste = NSButton(checkboxWithTitle: "Enviar ⌘V al destino anterior (requiere Accesibilidad)", target: nil, action: nil)
    private let custom = NSButton(checkboxWithTitle: "Conservar también formatos privados/desconocidos", target: nil, action: nil)
    private let reorder = NSButton(checkboxWithTitle: "Subir la copia al utilizarla", target: nil, action: nil)
    private let login = NSButton(checkboxWithTitle: "Abrir al iniciar sesión (opcional)", target: nil, action: nil)
    private let excluded = NSTextField(); private let allowed = NSTextField()
    private let days = NSTextField(); private let count = NSTextField(); private let size = NSTextField()
    private let poll = NSTextField(); private let separator = NSTextField()
    private let shortcut = NSPopUpButton(); private let appearance = NSPopUpButton()
    private let shortcuts = ShortcutConfiguration.presets
    init(preferences: Preferences, store: ClipStore) { self.preferences = preferences; self.store = store; super.init() }
    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [label, control]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3
        control.widthAnchor.constraint(equalToConstant: 520).isActive = true
        control.setAccessibilityLabel(title)
        return stack
    }
    func open() {
        if window == nil { build() }
        load(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 600, height: 520)
        window.title = "Ajustes — Memoria Local"; window.isReleasedWhenClosed = false
        window.delegate = self
        let title = NSTextField(wrappingLabelWithString: "Privacidad local: sin cuenta, red, telemetría ni sincronización. El historial puede contener información sensible. No está cifrado por esta aplicación; usa FileVault si corresponde. La app en primer plano es solo una aproximación del origen.")
        title.preferredMaxLayoutWidth = 520
        title.font = .systemFont(ofSize: 12)
        excluded.placeholderString = "com.ejemplo.app; com.otro.app"
        allowed.placeholderString = "Vacío = cualquier app no excluida"
        let warning = NSTextField(wrappingLabelWithString: "Los tipos marcados como ocultos/transitorios se omiten. No se garantiza detectar contraseñas ni todas las copias entre sondeos. Las URL de archivos son referencias, no respaldos de archivos.")
        warning.preferredMaxLayoutWidth = 520; warning.font = .systemFont(ofSize: 11); warning.textColor = .secondaryLabelColor
        shortcut.addItems(withTitles: shortcuts.map { $0.description } + ["Personalizado…"])
        shortcut.target = self; shortcut.action = #selector(shortcutChanged)
        appearance.addItems(withTitles: ["Sistema", "Claro", "Oscuro"])
        recorder.onRecorded = { [weak self] value in
            guard let self else { return }
            self.pendingShortcut = value; self.shortcutValue.stringValue = value.description
            self.shortcutMessage.stringValue = "Atajo preparado; pulsa Guardar para aplicarlo."
        }
        recorder.onMessage = { [weak self] text in self?.shortcutMessage.stringValue = text }
        shortcutValue.setAccessibilityLabel("Combinación del atajo global")
        shortcutMessage.preferredMaxLayoutWidth = 520
        shortcutMessage.font = .systemFont(ofSize: 11); shortcutMessage.textColor = .secondaryLabelColor
        let shortcutControls = NSStackView(views: [recorder, shortcutValue,
            NSButton(title: "Restablecer", target: self, action: #selector(resetShortcut))])
        shortcutControls.spacing = 8
        let shortcutGroup = NSStackView(views: [shortcut, shortcutControls, shortcutMessage])
        shortcutGroup.orientation = .vertical; shortcutGroup.alignment = .leading; shortcutGroup.spacing = 5
        shortcut.widthAnchor.constraint(equalToConstant: 520).isActive = true
        let numbers = NSStackView(); numbers.orientation = .horizontal; numbers.spacing = 8
        for (label, field) in [("Días (0=sin plazo)", days), ("Máximo copias", count), ("MiB historial", size), ("Sondeo ms", poll)] {
            let block = NSStackView(views: [NSTextField(labelWithString: label), field]); block.orientation = .vertical; block.alignment = .leading
            field.widthAnchor.constraint(equalToConstant: 120).isActive = true; field.setAccessibilityLabel(label)
            numbers.addArrangedSubview(block)
        }
        let actions = NSStackView(views: [NSButton(title: "Ver datos locales", target: self, action: #selector(revealData)),
                                            NSButton(title: "Vaciar historial a papelera…", target: self, action: #selector(trashAll)),
                                            NSButton(title: "Guardar", target: self, action: #selector(save))]); actions.spacing = 8
        let stack = NSStackView(views: [title, capture, autoPaste, custom, reorder, login,
                                       row("Excluir aplicaciones (identificadores separados por ;)", excluded),
                                       row("Permitir solo estas aplicaciones (opcional)", allowed), numbers,
                                       row("Separador para selección múltiple (\\n = salto, \\t = tabulador)", separator),
                                       row("Atajo global (sin permisos de monitorización del teclado)", shortcutGroup),
                                       row("Apariencia", appearance), warning, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 11; stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 720))
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]; scroll.drawsBackground = false
        let root = SettingsDocumentView(frame: NSRect(x: 0, y: 0, width: 580, height: 920))
        root.autoresizingMask = [.width]
        scroll.documentView = root; window.contentView = scroll; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
                                     stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
                                     stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -22)])
        root.layoutSubtreeIfNeeded()
        root.setFrameSize(NSSize(width: root.frame.width, height: max(920, stack.fittingSize.height + 40)))
        window.center()
    }
    private func load() {
        let d = preferences.defaults
        capture.state = preferences.enabled ? .on : .off
        autoPaste.state = d.bool(forKey: "autoPaste") ? .on : .off
        custom.state = d.bool(forKey: "customTypes") ? .on : .off
        reorder.state = d.bool(forKey: "reorder") ? .on : .off
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        excluded.stringValue = preferences.excluded.replacingOccurrences(of: "\n", with: "; ")
        allowed.stringValue = preferences.allowed.replacingOccurrences(of: "\n", with: "; ")
        days.stringValue = String(d.integer(forKey: "days")); count.stringValue = String(d.integer(forKey: "maxCount"))
        size.stringValue = String(d.integer(forKey: "megabytes")); poll.stringValue = String(d.integer(forKey: "pollMilliseconds"))
        separator.stringValue = preferences.separator.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
        recorder.cancelRecording()
        pendingShortcut = preferences.shortcut
        shortcut.selectItem(at: shortcuts.firstIndex(of: pendingShortcut) ?? shortcuts.count)
        refreshShortcut()
        appearance.selectItem(at: ["system", "light", "dark"].firstIndex(of: d.string(forKey: "appearance") ?? "system") ?? 0)
    }
    func windowWillClose(_ notification: Notification) { recorder.cancelRecording() }
    func windowDidResignKey(_ notification: Notification) { recorder.cancelRecording() }
    private func refreshShortcut() {
        recorder.isEnabled = shortcut.indexOfSelectedItem == shortcuts.count
        shortcutValue.stringValue = pendingShortcut.description
        shortcutMessage.stringValue = "Al menos un modificador. Teclas físicas: referencia ANSI; la leyenda puede variar según tu teclado. Guardar aplica el cambio."
    }
    @objc private func shortcutChanged() {
        recorder.cancelRecording()
        if shortcuts.indices.contains(shortcut.indexOfSelectedItem) { pendingShortcut = shortcuts[shortcut.indexOfSelectedItem] }
        refreshShortcut()
    }
    @objc private func resetShortcut() {
        recorder.cancelRecording(); pendingShortcut = .initial; shortcut.selectItem(at: 0); refreshShortcut()
    }
    private func normalized(_ field: NSTextField) throws -> String {
        let ids = field.stringValue.components(separatedBy: CharacterSet(charactersIn: ";\n,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard ids.allSatisfy({ $0.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil }) else {
            throw LocalError("Usa identificadores de aplicación, sin rutas ni comodines (ej. com.apple.Safari).")
        }
        return ids.joined(separator: "\n")
    }
    @objc private func save() {
        recorder.cancelRecording()
        do {
            guard let daysValue = Int(days.stringValue), (0...36500).contains(daysValue),
                  let countValue = Int(count.stringValue), (1...100000).contains(countValue),
                  let sizeValue = Int(size.stringValue), (1...4096).contains(sizeValue),
                  let pollValue = Int(poll.stringValue), (150...2000).contains(pollValue) else {
                throw LocalError("Revisa los límites: días 0–36500, copias 1–100000, MiB 1–4096, sondeo 150–2000 ms.")
            }
            let excludedValue = try normalized(excluded); let allowedValue = try normalized(allowed)
            if capture.state == .on && !preferences.enabled {
                let alert = NSAlert(); alert.messageText = "¿Guardar nuevas copias en este Mac?"
                alert.informativeText = "A partir de ahora se guardarán texto, RTF/HTML e imágenes localmente hasta que pauses o desactives la captura. No se leerá la copia que ya existe al activar. Revisa exclusiones para aplicaciones sensibles."
                alert.addButton(withTitle: "Activar captura"); alert.addButton(withTitle: "Cancelar")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            // Do not persist any new shortcut unless Carbon has accepted it.
            try pendingShortcut.validate()
            do { try onShortcutSave?(pendingShortcut) }
            catch {
                pendingShortcut = preferences.shortcut
                shortcut.selectItem(at: shortcuts.firstIndex(of: pendingShortcut) ?? shortcuts.count)
                refreshShortcut()
                shortcutMessage.stringValue = "No se aplicó el cambio. Se conserva: \(pendingShortcut.description). \(error.localizedDescription)"
                throw error
            }
            try pendingShortcut.persist(in: preferences.defaults)
            let d = preferences.defaults
            d.set(capture.state == .on, forKey: "captureEnabled"); d.set(autoPaste.state == .on, forKey: "autoPaste")
            d.set(custom.state == .on, forKey: "customTypes"); d.set(reorder.state == .on, forKey: "reorder")
            d.set(excludedValue, forKey: "excluded"); d.set(allowedValue, forKey: "allowed")
            d.set(daysValue, forKey: "days"); d.set(countValue, forKey: "maxCount"); d.set(sizeValue, forKey: "megabytes"); d.set(pollValue, forKey: "pollMilliseconds")
            d.set(separator.stringValue.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t"), forKey: "separator")
            d.set(["system", "light", "dark"][appearance.indexOfSelectedItem], forKey: "appearance")
            // Registration failures are surfaced. No launch item is created without this opt-in.
            if login.state == .on && SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            else if login.state == .off && SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            preferences.applyAppearance(); try onSave?(); window.orderOut(nil)
        } catch { showError(error) }
    }
    private func showError(_ error: Error) { let alert = NSAlert(); alert.messageText = error.localizedDescription; alert.runModal() }
    @objc private func revealData() { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: store.path)]) }
    @objc private func trashAll() {
        let alert = NSAlert(); alert.messageText = "¿Mover todo el historial activo a papelera?"
        alert.informativeText = "Incluye favoritos y protegidos. Se pueden restaurar desde Papelera; no borra definitivamente ni toca respaldos."
        alert.addButton(withTitle: "Mover a papelera"); alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try store.trash(store.clips().map(\.id)); try onSave?() } catch { showError(error) }
    }
}
