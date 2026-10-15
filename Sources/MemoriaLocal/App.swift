// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import ClipCore

@main
struct MemoriaLocalMain {
    static func main() {
        if CommandLine.arguments.contains("--self-check") {
            do { try SyntheticChecks.run(); print("PASS synthetic-store-check; no clipboard access"); exit(0) }
            catch { fputs("FAIL synthetic-store-check: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: ClipStore!
    private let preferences = Preferences()
    private var monitor: ClipboardMonitor!
    private var paste: PasteCoordinator!
    private var history: HistoryController!
    private var settings: SettingsController!
    private var shortcut: GlobalShortcut!
    private var status: NSStatusItem!
    private var statusMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            if let identifier = Bundle.main.bundleIdentifier,
               NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
                throw LocalError("Memoria Local ya está abierta. Usa su icono de la barra de menús.")
            }
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("MemoriaLocal", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            store = try ClipStore(path: root.appendingPathComponent("history.sqlite").path)
            monitor = ClipboardMonitor(store: store, preferences: preferences, pasteboard: .general)
            paste = PasteCoordinator(monitor: monitor, preferences: preferences)
            history = HistoryController(store: store, preferences: preferences, monitor: monitor, paste: paste)
            settings = SettingsController(preferences: preferences, store: store)
            shortcut = GlobalShortcut()
            shortcut.action = { [weak self] in self?.openHistory() }
            history.onSettings = { [weak self] in self?.settings.open() }
            history.onPause = { [weak self] in self?.togglePause() }
            settings.onSave = { [weak self] in try self?.applySettings() }
            monitor.onChange = { [weak self] in self?.history.reload() }
            monitor.onMessage = { [weak self] in self?.history.message($0) }
            paste.onMessage = { [weak self] in self?.history.message($0) }
            installMenu()
            preferences.applyAppearance()
            do { try applySettings() } catch { showError(error) }
            if !preferences.enabled { openHistory(); history.message("Captura desactivada. Abre Ajustes para dar consentimiento y elegir exclusiones.") }
        } catch {
            showError(error); NSApp.terminate(nil)
        }
    }
    func applicationWillTerminate(_ notification: Notification) { monitor?.stop() }
    private func applySettings() throws {
        monitor.start()
        try store.retain(days: preferences.defaults.integer(forKey: "days"), count: preferences.defaults.integer(forKey: "maxCount"), megabytes: preferences.defaults.integer(forKey: "megabytes"))
        history.reload(); updateStatus()
        try shortcut.register(key: UInt32(preferences.defaults.integer(forKey: "hotKey")), modifiers: UInt32(preferences.defaults.integer(forKey: "hotModifiers")))
    }
    private func installMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.target = self; status.button?.action = #selector(statusClicked(_:))
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusMenu.delegate = self
        let main = NSMenu(); let appMenuItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Ajustes…", action: #selector(openSettings), keyEquivalent: ","))
        appMenu.addItem(.separator()); appMenu.addItem(NSMenuItem(title: "Salir de Memoria Local", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu; main.addItem(appMenuItem)
        let editItem = NSMenuItem(title: "Edición", action: nil, keyEquivalent: ""); let editMenu = NSMenu(title: "Edición")
        for (title, selector, key) in [("Deshacer", #selector(UndoManager.undo), "z"), ("Cortar", #selector(NSText.cut(_:)), "x"),
                                        ("Copiar", #selector(NSText.copy(_:)), "c"), ("Pegar", #selector(NSText.paste(_:)), "v"),
                                        ("Seleccionar todo", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key))
        }
        editItem.submenu = editMenu; main.addItem(editItem); NSApp.mainMenu = main
        updateStatus()
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        menu.removeAllItems()
        let state = NSMenuItem(title: !preferences.enabled ? "Captura desactivada" : preferences.paused ? "Captura en pausa" : "Captura activa · solo local", action: nil, keyEquivalent: "")
        menu.addItem(state)
        for (title, action) in [("Abrir historial", #selector(openHistory)),
                                (preferences.paused ? "Reanudar captura" : "Pausar captura", #selector(togglePause)),
                                ("Ajustes…", #selector(openSettings)), ("Acerca de / licencia", #selector(about))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator()); menu.addItem(NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
    private func updateStatus() {
        let paused = preferences.paused || !preferences.enabled
        status?.button?.image = NSImage(systemSymbolName: paused ? "pause.circle" : "doc.on.clipboard", accessibilityDescription: paused ? "Memoria Local: captura detenida" : "Memoria Local: captura activa")
        status?.button?.toolTip = "Memoria Local · \(paused ? "captura detenida" : "captura activa") · clic: historial · clic derecho: menú"
    }
    @objc private func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = status.button {
            statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        } else { openHistory() }
    }
    @objc private func openHistory() { history.open() }
    @objc private func openSettings() { settings.open() }
    @objc private func togglePause() { preferences.paused.toggle(); updateStatus(); history.reload() }
    @objc private func about() {
        let alert = NSAlert(); alert.messageText = "Memoria Local — nombre provisional"
        alert.informativeText = "Aplicación nativa local para macOS. GNU GPL versión 3. Implementación original guiada por un informe funcional de Ditto Clipboard; no es un producto de Ditto ni incluye sus marcas o logotipos. Sin nube ni telemetría. Consulta LICENSE, NOTICE y el código fuente correspondiente incluidos con la distribución. Esta compilación debe auditarse en macOS antes de distribuir."
        alert.addButton(withTitle: "Cerrar"); alert.runModal()
    }
    private func showError(_ error: Error) { let alert = NSAlert(); alert.messageText = error.localizedDescription; alert.runModal() }
}

enum SyntheticChecks {
    static func run() throws {
        let store = try ClipStore(path: ":memory:")
        let text = "Hola, ñ — 👩🏽‍💻\nsegunda línea 100%_"
        let reps = [Representation(item: 0, type: "public.utf8-plain-text", data: Data(text.utf8)),
                    Representation(item: 0, type: "public.html", data: Data("<b>Hola</b>".utf8)),
                    Representation(item: 1, type: "public.png", data: Data([137, 80, 78, 71]))]
        let captured = try store.capture(reps, title: "Prueba sintética", text: text, source: "test.synthetic")
        guard try store.representations(captured.id) == reps.sorted(by: { ($0.item, $0.type) < ($1.item, $1.type) }),
              try store.clips(search: "100%_").count == 1,
              try store.clips(search: "' OR 1=1 --").isEmpty,
              try store.capture(reps, title: "Duplicado", text: text, source: "test.synthetic").duplicate else { throw LocalError("Multiformato, búsqueda o deduplicación fallaron.") }
        var clip = try store.clips()[0]; clip.protected = true; try store.metadata(clip)
        try store.retain(days: 1, count: 1, megabytes: 1)
        guard try store.clips().count == 1 else { throw LocalError("Protección falló.") }
        try store.trash([clip.id]); guard try store.clips().isEmpty else { throw LocalError("Papelera falló.") }
        try store.restore([clip.id]); guard try store.clips().count == 1 else { throw LocalError("Restauración falló.") }
        let archive = try store.archive(); let second = try ClipStore(path: ":memory:")
        guard try second.importArchive(archive) == 1,
              try second.representations(second.clips()[0].id) == store.representations(clip.id) else { throw LocalError("Intercambio falló.") }
    }
}
