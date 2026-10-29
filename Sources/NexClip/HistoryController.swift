// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import ClipCore

final class HistoryTable: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.contains(.command), onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
final class UsedHistoryRow: NSTableRowView {
    var used = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard used else { return }
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.minX, y: bounds.minY, width: 4, height: bounds.height),
                     xRadius: 2, yRadius: 2).fill()
    }
}
final class HistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func resignKey() {
        super.resignKey()
        // This panel can be key while NexClip is inactive. Dismiss on actual
        // loss of keyboard focus, not on a process-deactivation transition.
        orderOut(nil)
    }
}

final class HistoryController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    let store: ClipStore
    let preferences: Preferences
    let monitor: ClipboardMonitor
    let paste: PasteCoordinator
    let panel: HistoryPanel
    let table = HistoryTable()
    let search = NSSearchField()
    let groupPopup = NSPopUpButton()
    let favoriteButton = NSButton(checkboxWithTitle: "Favoritos", target: nil, action: nil)
    let trashButton = NSButton(checkboxWithTitle: "Papelera", target: nil, action: nil)
    let regexButton = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    let information = NSTextField(labelWithString: "")
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    static func numberColumnWidth(for count: Int) -> CGFloat {
        // Positions are not shortcut hints. Allow every digit of the last row,
        // including large histories, without stealing more title space than needed.
        max(33, ceil((String(max(1, count)) as NSString).size(withAttributes: [.font: numberFont]).width) + 16)
    }
    var clips = [Clip]()
    var groupIDs = [String?]()
    var onSettings: (() -> Void)?
    var onPause: (() -> Void)?
    var accessibilityMessage: String?
    func hideForPermission() { panel.level = .normal; panel.orderOut(nil); recordOpening(.permissionHidden) }
    // Bounded, process-local metadata only. Export requires an explicit menu action.
    enum OpeningSource: String { case internalRequest, shortcut, statusClick, menu }
    private enum OpeningPhase: String {
        case requested, permissionBlocked, modalBlocked, destinationRemembered, groupsLoaded, historyLoaded
        case keyRequested, ordered, nextTurn, settled
        case becameActive, resignedActive, becameKey, resignedKey, hidden, permissionHidden
    }
    private var openingAttempt = 0
    private var openingSource = OpeningSource.internalRequest
    private var openingStarted = ProcessInfo.processInfo.systemUptime
    private var openingRecords = [String]()
    var openingDiagnostic: String {
        let commit = Bundle.main.object(forInfoDictionaryKey: "NexClipCommit") as? String ?? "unversioned-local"
        return (["NexClip — apertura v2 (panel no activante)", "commit=\(commit)",
                 "Solo metadatos; últimas 48 etapas en memoria. No prueba visibilidad física ni causa."] + openingRecords)
            .joined(separator: "\n") + "\n"
    }
    private func recordOpening(_ phase: OpeningPhase) {
        guard openingAttempt > 0 else { return }
        let ms = Int((ProcessInfo.processInfo.systemUptime - openingStarted) * 1000)
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(panel.frame) }
        openingRecords.append("attempt=\(openingAttempt) source=\(openingSource.rawValue) ms=\(ms) phase=\(phase.rawValue) active=\(NSApp.isActive) hidden=\(NSApp.isHidden) visible=\(panel.isVisible) key=\(panel.isKeyWindow) main=\(panel.isMainWindow) occluded=\(!panel.occlusionState.contains(.visible)) onSpace=\(panel.isOnActiveSpace) intersectsScreen=\(onScreen) modal=\(NSApp.modalWindow != nil) permissionBusy=\(paste.permissionBusy)")
        if openingRecords.count > 48 { openingRecords.removeFirst(openingRecords.count - 48) }
    }
    @objc private func openingNotification(_ note: Notification) {
        switch note.name {
        case NSApplication.didBecomeActiveNotification: recordOpening(.becameActive)
        case NSApplication.didResignActiveNotification: recordOpening(.resignedActive)
        case NSWindow.didBecomeKeyNotification: recordOpening(.becameKey)
        case NSWindow.didResignKeyNotification: recordOpening(.resignedKey)
        default: break
        }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    private var previewWindows = [NSWindow]()
    var selection: [Clip] { table.selectedRowIndexes.compactMap { $0 < clips.count ? clips[$0] : nil } }

    init(store: ClipStore, preferences: Preferences, monitor: ClipboardMonitor, paste: PasteCoordinator) {
        self.store = store; self.preferences = preferences; self.monitor = monitor; self.paste = paste
        panel = HistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 550, height: 470),
                             styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "NexClip — historial"
        panel.isReleasedWhenClosed = false; panel.level = .floating
        // Scoped to this nonactivating history panel; Settings/modals keep their
        // own activation behavior. resignKey supplies the dismissal contract.
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 450, height: 300)
        panel.setFrameAutosaveName("HistoryPanel")
        if !panel.setFrameUsingName("HistoryPanel") { panel.center() }
        build()
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(openingNotification(_:)), name: name, object: NSApp)
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(openingNotification(_:)), name: name, object: panel)
        }
    }
    private func button(_ name: String, _ selector: Selector) -> NSButton { NSButton(title: name, target: self, action: selector) }
    private func build() {
        let root = NSView(); panel.contentView = root
        let top = NSStackView(views: [groupPopup, favoriteButton, trashButton,
                                      button("Pausa", #selector(pauseCapture)), button("Ajustes…", #selector(settings))])
        top.orientation = .horizontal; top.spacing = 8
        groupPopup.target = self; groupPopup.action = #selector(filterChanged)
        groupPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        favoriteButton.target = self; favoriteButton.action = #selector(filterChanged)
        trashButton.target = self; trashButton.action = #selector(filterChanged)
        let number = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("number")); number.width = 33; number.minWidth = 33; number.maxWidth = 33
        let title = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title")); title.width = 450
        table.addTableColumn(number); table.addTableColumn(title); table.headerView = nil
        table.delegate = self; table.dataSource = self; table.rowHeight = 49
        table.allowsMultipleSelection = true; table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self; table.action = #selector(clickedRow); table.doubleAction = #selector(pasteSelected)
        table.setAccessibilityLabel("Historial de copias")
        table.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        let context = NSMenu(); context.delegate = self; table.menu = context
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        search.placeholderString = "Buscar texto, título o alias…"; search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Buscar en el historial")
        regexButton.target = self; regexButton.action = #selector(filterChanged)
        regexButton.toolTip = "Expresiones simples sobre título, alias y los primeros 8192 caracteres. No es el dialecto de Ditto."
        let actions = button("Acciones ▾", #selector(showActions))
        let bottom = NSStackView(views: [search, regexButton, actions]); bottom.spacing = 6
        information.font = .systemFont(ofSize: 11); information.textColor = .secondaryLabelColor
        information.maximumNumberOfLines = 2; information.lineBreakMode = .byWordWrapping
        let stack = NSStackView(views: [top, scroll, bottom, information]); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 7; stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 9), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor), information.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120), groupPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 110)
        ])
        table.nextKeyView = search; search.nextKeyView = table
        panel.initialFirstResponder = search
    }
    func open(source: OpeningSource = .internalRequest) {
        openingAttempt += 1; openingSource = source; openingStarted = ProcessInfo.processInfo.systemUptime
        recordOpening(.requested)
        guard !paste.permissionBusy else {
            recordOpening(.permissionBlocked); message("Esperando permiso de macOS…"); return
        }
        guard NSApp.modalWindow == nil else { recordOpening(.modalBlocked); return }
        panel.level = .floating
        paste.rememberDestination(); recordOpening(.destinationRemembered)
        reloadGroups(); recordOpening(.groupsLoaded)
        // A stale search/group/trash filter must not hide the opening target.
        search.stringValue = ""; groupPopup.selectItem(at: 0)
        favoriteButton.state = .off; trashButton.state = .off; regexButton.state = .off
        reload(); recordOpening(.historyLoaded)
        // A nonactivating panel borrows keyboard focus without activating NexClip
        // or scheduling a later process activation that could steal focus back.
        panel.makeKeyAndOrderFront(nil)
        recordOpening(.keyRequested)
        if let row = ClipStore.initialSelection(in: clips) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row); panel.makeFirstResponder(table)
        } else { panel.makeFirstResponder(search) }
        recordOpening(.ordered)
        let attempt = openingAttempt
        DispatchQueue.main.async { [weak self] in
            guard let self, self.openingAttempt == attempt else { return }
            self.recordOpening(.nextTurn)
        }
        // Measurement only: never re-show/reactivate the panel from a timer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.openingAttempt == attempt else { return }
            self.recordOpening(.settled)
        }
    }
    func hide() { panel.orderOut(nil); recordOpening(.hidden) }
    func message(_ value: String) { information.stringValue = value; information.toolTip = value }
    func perform(_ action: () throws -> Void) {
        do { try action() } catch { message(error.localizedDescription) }
    }
    func reloadGroups() {
        let selected = groupPopup.indexOfSelectedItem
        let old = selected >= 0 && selected < groupIDs.count ? groupIDs[selected] : nil
        perform {
            let groups = try store.groups()
            groupPopup.removeAllItems(); groupPopup.addItem(withTitle: "Todos los grupos"); groupIDs = [nil]
            func add(_ parent: String?, depth: Int) {
                for group in groups where group.parent == parent {
                    groupPopup.addItem(withTitle: String(repeating: "  ", count: depth) + group.name)
                    groupIDs.append(group.id)
                    if depth < 32 { add(group.id, depth: depth + 1) }
                }
            }
            add(nil, depth: 0)
            if let index = groupIDs.firstIndex(where: { $0 == old }) { groupPopup.selectItem(at: index) }
        }
    }
    func reload() {
        let ids = Set(selection.map(\.id))
        perform {
            let index = groupPopup.indexOfSelectedItem
            let group = index >= 0 && index < groupIDs.count ? groupIDs[index] : nil
            clips = try store.clips(search: search.stringValue, regex: regexButton.state == .on,
                                    favorites: favoriteButton.state == .on, group: group, trash: trashButton.state == .on)
            if let number = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("number")) {
                let width = Self.numberColumnWidth(for: clips.count)
                number.maxWidth = .greatestFiniteMagnitude
                number.minWidth = width; number.maxWidth = width; number.width = width
            }
            table.reloadData()
            let restored = IndexSet(clips.indices.filter { ids.contains(clips[$0].id) })
            table.selectRowIndexes(restored.isEmpty && !clips.isEmpty ? IndexSet(integer: 0) : restored, byExtendingSelection: false)
            message(accessibilityMessage ?? "\(clips.count) copias · \(!preferences.enabled ? "captura desactivada" : preferences.paused ? "en pausa" : "captura activa") · ↵ pegar · ⇧↵ texto · Espacio vista")
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { clips.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = UsedHistoryRow(); view.used = clips[row].usedAt != nil; return view
    }
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? UsedHistoryRow)?.used = clips[row].usedAt != nil
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let clip = clips[row]
        if tableColumn?.identifier.rawValue == "number" {
            let label = NSTextField(labelWithString: "\(row + 1)")
            label.font = Self.numberFont
            label.setAccessibilityLabel("Posición \(row + 1)")
            label.textColor = .secondaryLabelColor; label.alignment = .center; return label
        }
        let flags = (clip.favorite ? "★ " : "") + (clip.protected ? "🔒 " : "") + (clip.sticky == 1 ? "↑ " : clip.sticky == -1 ? "↓ " : "")
        let title = NSTextField(labelWithString: flags + clip.title)
        title.font = .systemFont(ofSize: 13); title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: "\(clip.source) · \(ByteCountFormatter.string(fromByteCount: Int64(clip.bytes), countStyle: .file))\(clip.alias.map { " · /" + $0 } ?? "")")
        detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [title, detail]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3
        stack.setAccessibilityLabel(flags + clip.title)
        return stack
    }
    func controlTextDidChange(_ obj: Notification) { reload() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.moveDown(_:)) { panel.makeFirstResponder(table); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { pasteSelected(nil); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { hide(); return true }
        return false
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 36, 76: pasteSelection(plain: event.modifierFlags.contains(.shift)); return true
        case 53: hide(); return true
        case 49: preview(); return true
        case 48: panel.makeFirstResponder(search); return true
        case 51, 117: commandAction("trash"); return true
        default: break
        }
        if command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": panel.makeFirstResponder(search); return true
            case "c": copySelection(); return true
            case "e": edit(); return true
            default: break
            }
        }
        if event.modifierFlags.contains(.option), let character = event.charactersIgnoringModifiers,
           let number = Int(character), number >= 1, number <= min(9, clips.count) {
            table.selectRowIndexes(IndexSet(integer: number - 1), byExtendingSelection: false); pasteSelection(plain: false); return true
        }
        if !command && !event.modifierFlags.contains(.control), let characters = event.characters,
           !characters.isEmpty, characters.unicodeScalars.allSatisfy({
               !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
           }) {
            // Let the field editor handle the original event (layout/Option/Unicode), not a key-code map.
            search.stringValue = ""; reload(); panel.makeFirstResponder(search)
            search.currentEditor()?.keyDown(with: event)
            return true
        }
        return false
    }
    @objc private func clickedRow() {
        guard let event = NSApp.currentEvent, event.type == .leftMouseUp || event.type == .leftMouseDown else { return }
        useClickedRow(table.clickedRow)
    }
    func useClickedRow(_ row: Int) {
        guard clips.indices.contains(row), !clips[row].deleted else { return }
        // A single click records intent, without pasting or moving a double-click target.
        perform { try recordUse([clips[row].id], reorder: false) }
    }
    private func recordUse(_ ids: [String], reorder: Bool) throws {
        let now = Date().timeIntervalSince1970
        try store.markUsed(ids, reorder: reorder, now: now)
        for row in clips.indices where ids.contains(clips[row].id) && !clips[row].deleted {
            clips[row].usedAt = now
            if reorder { clips[row].lastUsed = now }
            (table.rowView(atRow: row, makeIfNecessary: false) as? UsedHistoryRow)?.used = true
        }
    }
    @objc private func filterChanged() { reload() }
    @objc private func settings() { onSettings?() }
    @objc private func pauseCapture() { onPause?(); reload() }
    @objc private func pasteSelected(_ sender: Any?) { pasteSelection(plain: NSEvent.modifierFlags.contains(.shift)) }
    func assembled(plain: Bool, transform: TextTransform? = nil) throws -> [Representation] {
        let selected = selection
        guard !selected.isEmpty, !selected.contains(where: \.deleted) else { throw LocalError("Selecciona una copia activa.") }
        if selected.count == 1 && !plain && transform == nil { return try store.representations(selected[0].id) }
        // Multi-selection is deliberately a single joined text paste, never a delayed sequence.
        var text = selected.map(\.text).joined(separator: preferences.separator)
        guard !text.isEmpty else { throw LocalError("La selección no tiene texto disponible. Usa el formato original.") }
        if let transform { text = transform.apply(text) }
        return [Representation(item: 0, type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))]
    }
    func pasteSelection(plain: Bool = false, transform: TextTransform? = nil) {
        perform {
            let ids = selection.map(\.id)
            let reps = try assembled(plain: plain, transform: transform)
            try paste.paste(reps, hide: hide)
            try recordUse(ids, reorder: preferences.defaults.bool(forKey: "reorder"))
        }
    }
    func copySelection() {
        perform {
            let ids = selection.map(\.id)
            try monitor.write(assembled(plain: false))
            try recordUse(ids, reorder: preferences.defaults.bool(forKey: "reorder"))
            message("Copiado al portapapeles, sin enviar teclas.")
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === table.menu, clips.indices.contains(table.clickedRow), !table.isRowSelected(table.clickedRow) {
            table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        }
        fillMenu(menu)
    }
    private func menuItem(_ title: String, _ command: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = command; return item
    }
    private func fillMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for (title, cmd) in [("Pegar formato original ↵", "paste"), ("Pegar solo texto ⇧↵", "plain"), ("Copiar sin pegar ⌘C", "copy"),
                             ("Vista previa / formatos", "preview"), ("Mostrar QR local", "qr"), ("Propiedades…", "properties"),
                             ("Editar texto como copia nueva…", "edit"), ("Favorito: alternar", "favorite"),
                             ("Proteger: alternar", "protect"), ("Fijar arriba", "top"), ("Fijar abajo", "bottom"), ("No fijar", "unstick")] {
            menu.addItem(menuItem(title, cmd))
        }
        let transform = NSMenu(title: "Transformar y pegar texto")
        for value in TextTransform.allCases { transform.addItem(menuItem(value.rawValue, "transform:" + value.rawValue)) }
        let t = NSMenuItem(title: transform.title, action: nil, keyEquivalent: ""); t.submenu = transform; menu.addItem(t)
        let groups = NSMenu(title: "Mover al grupo")
        groups.addItem(menuItem("Sin grupo", "move:"))
        if let values = try? store.groups() {
            func add(_ parent: String?, depth: Int) {
                for group in values where group.parent == parent {
                    groups.addItem(menuItem(String(repeating: "  ", count: depth) + group.name, "move:" + group.id))
                    if depth < 32 { add(group.id, depth: depth + 1) }
                }
            }
            add(nil, depth: 0)
        }
        let g = NSMenuItem(title: groups.title, action: nil, keyEquivalent: ""); g.submenu = groups; menu.addItem(g)
        menu.addItem(.separator())
        for slot in 1...3 {
            menu.addItem(menuItem("Guardar primera copia en buffer \(slot)", "bufferSet:\(slot)"))
            menu.addItem(menuItem("Pegar buffer \(slot)", "bufferPaste:\(slot)"))
        }
        menu.addItem(.separator())
        for (title, cmd) in [("Nuevo grupo…", "newGroup"), ("Renombrar grupo actual…", "renameGroup"), ("Eliminar grupo vacío de subgrupos…", "removeGroup"),
                             ("Exportar selección…", "export"), ("Exportar texto/imagen…", "exportStandard"), ("Importar archivo de copias…", "import"),
                             ("Crear respaldo SQLite…", "backup"), ("Restaurar respaldo (fusionar)…", "restoreBackup"), ("Compactar sin borrar copias", "compact"),
                             ("Mover selección a papelera", "trash"), ("Restaurar selección", "restore"), ("Eliminar selección definitivamente…", "delete")] {
            menu.addItem(menuItem(title, cmd))
        }
    }
    @objc func showActions(_ sender: NSButton) {
        let menu = NSMenu(); fillMenu(menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
    @objc private func menuCommand(_ sender: NSMenuItem) { if let command = sender.representedObject as? String { commandAction(command) } }
    func commandAction(_ command: String) {
        perform {
            if command.hasPrefix("move:") {
                let group = String(command.dropFirst(5))
                for var clip in selection { clip.group = group.isEmpty ? nil : group; try store.metadata(clip) }
            } else if command.hasPrefix("transform:"), let value = TextTransform(rawValue: String(command.dropFirst(10))) {
                pasteSelection(plain: true, transform: value); return
            } else if command.hasPrefix("bufferSet:"), let slot = Int(command.dropFirst(10)), let clip = selection.first {
                _ = try store.buffer(slot, clip: clip.id)
            } else if command.hasPrefix("bufferPaste:"), let slot = Int(command.dropFirst(12)) {
                guard let id = try store.buffer(slot) else { throw LocalError("Buffer vacío o copia en papelera.") }
                try paste.paste(store.representations(id), hide: hide)
                try recordUse([id], reorder: preferences.defaults.bool(forKey: "reorder"))
            } else {
                switch command {
                case "paste": pasteSelection(); return
                case "plain": pasteSelection(plain: true); return
                case "copy": copySelection(); return
                case "preview": preview(); return
                case "qr": preview(qr: true); return
                case "properties": properties(); return
                case "edit": edit(); return
                case "favorite", "protect", "top", "bottom", "unstick":
                    try store.transaction {
                        for var clip in selection {
                            switch command {
                            case "favorite": clip.favorite.toggle()
                            case "protect": clip.protected.toggle()
                            case "top": clip.sticky = 1
                            case "bottom": clip.sticky = -1
                            default: clip.sticky = 0
                            }
                            try store.metadata(clip)
                        }
                    }
                case "newGroup":
                    if let name = ask("Nuevo grupo", value: "", note: "Se creará dentro del grupo actualmente seleccionado.") {
                        try store.addGroup(name: name, parent: currentGroup)
                    }
                case "renameGroup":
                    guard let id = currentGroup else { throw LocalError("Elige un grupo concreto.") }
                    if let name = ask("Renombrar grupo", value: "") { try store.renameGroup(id: id, name: name) }
                case "removeGroup":
                    guard let id = currentGroup else { throw LocalError("Elige un grupo concreto.") }
                    if confirm("¿Eliminar el grupo?", "Las copias pasarán a «Sin grupo». No se permiten grupos con subgrupos.") { try store.removeGroup(id: id) }
                case "trash":
                    guard !selection.isEmpty else { return }
                    if selection.contains(where: { $0.protected || $0.favorite }), !confirm("¿Mover copias protegidas o favoritas a papelera?", "No se borrarán definitivamente.") { return }
                    try store.trash(selection.map(\.id))
                case "restore": try store.restore(selection.map(\.id))
                case "delete":
                    guard trashButton.state == .on, !selection.isEmpty else { throw LocalError("Solo se elimina definitivamente desde la papelera.") }
                    if confirm("¿Eliminar \(selection.count) copias definitivamente?", "Es irreversible. Los respaldos y exportaciones existentes no se modificarán.") { try store.deletePermanently(selection.map(\.id)) }
                case "export": try exportArchive()
                case "exportStandard": try exportStandard()
                case "import": try importArchive()
                case "backup":
                    if let url = saveURL(name: "NexClip-respaldo.sqlite") { try store.backup(to: url); message("Respaldo verificado: \(url.lastPathComponent)"); return }
                case "restoreBackup":
                    if let url = openURL(), confirm("¿Fusionar este respaldo?", "Conserva las copias actuales; no sobrescribe la base ni restaura la papelera. Crea primero un respaldo si necesitas un punto de retorno.") {
                        let count = try store.mergeBackup(url); message("Restauradas \(count) copias nuevas (sin sobrescribir)."); reloadGroups(); reload(); return
                    }
                case "compact": try store.compact()
                default: break
                }
            }
            reloadGroups(); reload()
        }
    }
    var currentGroup: String? {
        let index = groupPopup.indexOfSelectedItem
        return index >= 0 && index < groupIDs.count ? groupIDs[index] : nil
    }
    func ask(_ title: String, value: String, note: String = "") -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = note
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 340, height: 26)
        alert.accessoryView = field; alert.addButton(withTitle: "Guardar"); alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
    func confirm(_ title: String, _ note: String) -> Bool {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = title; alert.informativeText = note
        alert.addButton(withTitle: "Continuar"); alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func properties() {
        guard var clip = selection.first else { return }
        perform {
            let formats = try store.representations(clip.id).map { "ítem \($0.item + 1) · \($0.type) · \($0.data.count) bytes" }.joined(separator: "\n")
            let date = Date(timeIntervalSince1970: clip.created).formatted(date: .abbreviated, time: .shortened)
            let used = clip.lastUsed.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "ninguno"
            if let title = ask("Título de la copia", value: clip.title,
                               note: "Origen aproximado: \(clip.source)\nCreada: \(date) · Último envío/copia: \(used)\nCapturas: \(clip.copies)\n\(formats)") {
                clip.title = title
                if let alias = ask("Alias de búsqueda (único)", value: clip.alias ?? "", note: "Vacío para quitarlo. Los atajos globales por copia están pendientes.") { clip.alias = alias }
                try store.metadata(clip); reload()
            }
        }
    }
    func edit() {
        guard let clip = selection.first else { return }
        let alert = NSAlert(); alert.messageText = "Editar como una copia de texto nueva"
        alert.informativeText = "El original y sus formatos permanecen intactos. La nueva copia solo contiene texto."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 260)); scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds); text.isRichText = false; text.string = clip.text
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]; scroll.documentView = text
        alert.accessoryView = scroll; alert.addButton(withTitle: "Guardar copia nueva"); alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn {
            perform {
                try store.capture([Representation(item: 0, type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.string.utf8))], title: String(text.string.prefix(120)), text: text.string, source: "Edición local")
                reload()
            }
        }
    }
    func preview(qr: Bool = false) {
        guard let clip = selection.first else { return }
        perform {
            let reps = try store.representations(clip.id)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = qr ? "QR local" : "Vista previa — " + clip.title
            if qr {
                guard let image = Preview.qr(clip.text) else { throw LocalError("QR no disponible: texto vacío/grande o capacidad excedida (máximo 2000 bytes).") }
                let view = NSImageView(image: image); view.imageScaling = .scaleProportionallyUpOrDown; window.contentView = view
            } else {
                let tabs = NSTabView(); tabs.tabViewType = .topTabsBezelBorder
                for (index, rep) in reps.enumerated() {
                    let tab = NSTabViewItem(identifier: index)
                    tab.label = "\(rep.item + 1): " + rep.type.replacingOccurrences(of: "public.", with: "")
                    if let image = Preview.image(rep.data) {
                        let view = NSImageView(image: image); view.imageScaling = .scaleProportionallyUpOrDown; tab.view = view
                    } else {
                        let text: String
                        if rep.type == NSPasteboard.PasteboardType.rtf.rawValue {
                            text = ClipboardMonitor.plainText([rep])
                        } else { text = String(data: rep.data, encoding: .utf8) ?? "Formato binario: \(rep.data.count) bytes. Se conserva sin interpretar." }
                        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
                        let view = NSTextView(); view.isEditable = false; view.isRichText = false
                        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                        view.string = String(text.prefix(200000)) + (text.count > 200000 ? "\n[Vista limitada; el dato original se conserva]" : "")
                        view.isVerticallyResizable = true; view.autoresizingMask = [.width]
                        scroll.documentView = view; tab.view = scroll
                    }
                    tabs.addTabViewItem(tab)
                }
                window.contentView = tabs
            }
            previewWindows.removeAll { !$0.isVisible }
            previewWindows.append(window); window.center(); window.makeKeyAndOrderFront(nil)
        }
    }
    func saveURL(name: String) -> URL? {
        let dialog = NSSavePanel(); dialog.nameFieldStringValue = name
        return dialog.runModal() == .OK ? dialog.url : nil
    }
    func openURL() -> URL? {
        let dialog = NSOpenPanel(); dialog.allowsMultipleSelection = false; dialog.canChooseDirectories = false
        return dialog.runModal() == .OK ? dialog.url : nil
    }
    func exportArchive() throws {
        guard !selection.isEmpty, !selection.contains(where: \.deleted) else { throw LocalError("Selecciona copias activas para exportar; restaura antes las de papelera.") }
        guard let url = saveURL(name: "copias.memorialocal.json") else { return }
        let data = try JSONEncoder().encode(store.archive(ids: selection.map(\.id)))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func importArchive() throws {
        guard let url = openURL() else { return }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 128 * 1024 * 1024 else { throw LocalError("La importación supera 128 MiB.") }
        let archive = try JSONDecoder().decode(ClipArchive.self, from: Data(contentsOf: url))
        guard confirm("¿Importar \(archive.clips.count) copias?", "Archivo local con contenido potencialmente sensible. No se reemplazarán copias actuales.") else { return }
        let count = try store.importArchive(archive)
        message("Importadas \(count) copias nuevas.")
    }
    func exportStandard() throws {
        guard let clip = selection.first else { return }
        let reps = try store.representations(clip.id)
        let image = reps.first { $0.type == NSPasteboard.PasteboardType.png.rawValue }
        guard let url = saveURL(name: image == nil ? "copia.txt" : "copia.png") else { return }
        try (image?.data ?? Data(clip.text.utf8)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
