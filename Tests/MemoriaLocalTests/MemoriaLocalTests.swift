// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import AppKit
import Carbon
import ClipCore
@testable import MemoriaLocal

final class MemoriaLocalTests: XCTestCase {
    private func text(_ string: String, item: Int = 0) -> Representation {
        Representation(item: item, type: NSPasteboard.PasteboardType.string.rawValue, data: Data(string.utf8))
    }
    func testShortcutCarbonModifiers() {
        let pairs: [(NSEvent.ModifierFlags, UInt32)] = [(.control, UInt32(controlKey)), (.option, UInt32(optionKey)),
                                                        (.shift, UInt32(shiftKey)), (.command, UInt32(cmdKey))]
        for (flag, carbon) in pairs { XCTAssertEqual(ShortcutConfiguration.carbonModifiers(from: flag), carbon) }
        XCTAssertEqual(ShortcutConfiguration.carbonModifiers(from: [.control, .option, .shift, .command, .capsLock, .function, .numericPad]), ShortcutConfiguration.modifierMask)
        XCTAssertEqual(ShortcutConfiguration.carbonModifiers(from: [.capsLock, .function, .numericPad]), 0)
        XCTAssertEqual(ShortcutConfiguration.carbonModifiers(from: []), 0)
    }
    func testShortcutRequiresModifierAndRealKey() throws {
        for flag in [NSEvent.ModifierFlags.control, .option, .shift, .command] {
            XCTAssertNoThrow(try ShortcutConfiguration(keyCode: 0, modifiers: ShortcutConfiguration.carbonModifiers(from: flag)).validate())
        }
        for value in [ShortcutConfiguration(keyCode: 0, modifiers: 0),
                      .init(keyCode: 55, modifiers: UInt32(cmdKey)),
                      .init(keyCode: 128, modifiers: UInt32(optionKey)),
                      .init(keyCode: 9, modifiers: UInt32(cmdKey) | (1 << 31))] {
            XCTAssertFalse(value.isValid); XCTAssertThrowsError(try value.validate())
        }
    }
    func testShortcutTextUsesPhysicalKeyAndStableModifierOrder() {
        XCTAssertEqual(ShortcutConfiguration.initial.description, "⌃⌥ `")
        XCTAssertEqual(ShortcutConfiguration.presets[1].description, "⌃⌥ Espacio")
        XCTAssertEqual(ShortcutConfiguration.presets[2].description, "⌃⇧ V")
        XCTAssertEqual(ShortcutConfiguration(keyCode: 0, modifiers: ShortcutConfiguration.modifierMask).description, "⌃⌥⇧⌘ A")
        XCTAssertEqual(ShortcutConfiguration.keyName(122), "F1")
        XCTAssertEqual(ShortcutConfiguration.keyName(123), "←")
        XCTAssertEqual(ShortcutConfiguration.keyName(10), "Tecla física 10")
    }
    func testShortcutLegacyPreferencesAndRoundTrip() throws {
        let suite = "MemoriaLocal-shortcut-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults)
        XCTAssertEqual(preferences.shortcut, .initial)
        // Existing releases wrote exactly these integer keys, in Carbon units.
        defaults.set(9, forKey: "hotKey"); defaults.set(Int(controlKey | shiftKey), forKey: "hotModifiers")
        XCTAssertEqual(preferences.shortcut, ShortcutConfiguration.presets[2])
        let custom = ShortcutConfiguration(keyCode: 40, modifiers: UInt32(cmdKey | optionKey))
        try custom.persist(in: defaults)
        XCTAssertEqual(Preferences(try XCTUnwrap(UserDefaults(suiteName: suite))).shortcut, custom)
        XCTAssertEqual(defaults.integer(forKey: "hotKey"), 40)
        XCTAssertEqual(defaults.integer(forKey: "hotModifiers"), Int(cmdKey | optionKey))
        XCTAssertThrowsError(try ShortcutConfiguration(keyCode: 0, modifiers: 0).persist(in: defaults))
        XCTAssertEqual(preferences.shortcut, custom)
        defaults.set(-1, forKey: "hotKey"); XCTAssertEqual(preferences.shortcut, .initial)
        defaults.set(40, forKey: "hotKey"); defaults.set(0, forKey: "hotModifiers")
        XCTAssertEqual(preferences.shortcut, .initial)
        try ShortcutConfiguration.initial.persist(in: defaults)
        XCTAssertEqual(preferences.shortcut, .initial)
    }
    func testShortcutRegistrationFailureKeepsPreviousHandleAndPreferences() throws {
        let suite = "MemoriaLocal-shortcut-registration-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = [String](); var fail = false
        let registration = ShortcutRegistration<UInt32>(acquire: { value in
            calls.append("acquire-\(value.keyCode)")
            if fail { throw LocalError("occupied") }
            return value.keyCode
        }, release: { calls.append("release-\($0)") })
        let previous = ShortcutConfiguration.initial; let candidate = ShortcutConfiguration.presets[2]
        try registration.replace(with: previous); try previous.persist(in: defaults)
        fail = true
        XCTAssertThrowsError(try { try registration.replace(with: candidate); try candidate.persist(in: defaults) }())
        XCTAssertEqual(registration.configuration, previous)
        XCTAssertEqual(ShortcutConfiguration.load(from: defaults), previous)
        XCTAssertEqual(calls, ["acquire-50", "acquire-9"])
        fail = false
        try registration.replace(with: candidate); try candidate.persist(in: defaults)
        XCTAssertEqual(calls, ["acquire-50", "acquire-9", "acquire-9", "release-50"])
        XCTAssertEqual(ShortcutConfiguration.load(from: defaults), candidate)
        try registration.replace(with: candidate) // No conflict with our own unchanged shortcut.
        XCTAssertEqual(calls.count, 4)
        XCTAssertThrowsError(try registration.replace(with: .init(keyCode: 0, modifiers: 0)))
        XCTAssertEqual(registration.configuration, candidate); XCTAssertEqual(calls.count, 4)
    }
    func testSyntheticProductionStore() throws { try SyntheticChecks.run() }
    func testHashPreservesItemBoundariesAndIgnoresRepresentationEnumerationOrder() {
        let a = [text("abc"), Representation(item: 0, type: "public.html", data: Data("<b>abc</b>".utf8))]
        XCTAssertEqual(ClipStore.fingerprint(a), ClipStore.fingerprint(Array(a.reversed())))
        XCTAssertNotEqual(ClipStore.fingerprint([text("abc", item: 0)]), ClipStore.fingerprint([text("abc", item: 1)]))
        XCTAssertNotEqual(ClipStore.fingerprint([text("ab"), text("c", item: 1)]), ClipStore.fingerprint([text("a"), text("bc", item: 1)]))
    }
    func testLiteralSearchAndRegexError() throws {
        let store = try ClipStore(path: ":memory:")
        try store.capture([text("100%_ más ' OR 1=1")], title: "Ejemplo", text: "100%_ más ' OR 1=1", source: "test")
        try store.capture([text("otro")], title: "Segundo", text: "otro", source: "test")
        XCTAssertEqual(try store.clips(search: "100%_").count, 1)
        XCTAssertTrue(try store.clips(search: "' OR 1=1 --").isEmpty)
        XCTAssertThrowsError(try store.clips(search: "[", regex: true))
        XCTAssertEqual(try store.clips(search: "100.*", regex: true).count, 1)
        XCTAssertThrowsError(try store.clips(search: "(a+)+$", regex: true))
    }
    func testGroupsFavoritesProtectedRetentionAndTrash() throws {
        let store = try ClipStore(path: ":memory:")
        try store.addGroup(name: "Padre", parent: nil)
        let parent = try store.groups()[0]
        try store.addGroup(name: "Hijo", parent: parent.id)
        let child = try XCTUnwrap(store.groups().first { $0.parent == parent.id })
        let first = try store.capture([text("A")], title: "A", text: "A", source: "test", now: 1)
        try store.capture([text("B")], title: "B", text: "B", source: "test", now: 2)
        var clip = try XCTUnwrap(store.clips().first { $0.id == first.id })
        clip.group = child.id; clip.favorite = true; clip.protected = true; clip.alias = "rápido"
        try store.metadata(clip)
        XCTAssertEqual(try store.clips(group: parent.id).map(\.id), [first.id])
        XCTAssertEqual(try store.clips(favorites: true).map(\.id), [first.id])
        try store.retain(days: 1, count: 1, megabytes: 1)
        XCTAssertEqual(try store.clips().map(\.id), [first.id])
        XCTAssertEqual(try store.clips(trash: true).count, 1)
        XCTAssertThrowsError(try store.removeGroup(id: parent.id))
        try store.removeGroup(id: child.id)
        XCTAssertNil(try store.clips()[0].group)
        try store.trash([first.id]); XCTAssertTrue(try store.clips().isEmpty)
        try store.restore([first.id]); XCTAssertEqual(try store.representations(first.id), [text("A")])
    }
    func testArchiveImportValidationAndRoundTrip() throws {
        let store = try ClipStore(path: ":memory:")
        try store.addGroup(name: "Textos", parent: nil)
        try store.capture([text("ñ 🦉"), Representation(item: 0, type: "public.rtf", data: Data("{\\rtf1 hola}".utf8))], title: "Uno", text: "ñ 🦉", source: "test")
        var clip = try store.clips()[0]; clip.group = try store.groups()[0].id; clip.favorite = true; try store.metadata(clip)
        let encoded = try JSONEncoder().encode(store.archive())
        let archive = try JSONDecoder().decode(ClipArchive.self, from: encoded)
        let other = try ClipStore(path: ":memory:")
        XCTAssertEqual(try other.importArchive(archive), 1)
        XCTAssertEqual(try other.importArchive(archive), 0)
        let imported = try other.clips()[0]
        XCTAssertTrue(imported.favorite); XCTAssertNotNil(imported.group)
        XCTAssertEqual(try other.representations(imported.id), try store.representations(clip.id))
        var invalid = archive; invalid.version = 99
        XCTAssertThrowsError(try other.importArchive(invalid))
        invalid = archive; invalid.groups = [ClipGroup(id: "a", name: "Ciclo", parent: "a")]
        XCTAssertThrowsError(try other.importArchive(invalid))
        XCTAssertEqual(try other.clips().count, 1)
    }
    func testBackupMergeDoesNotOverwriteAndRefusesOverwrite() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        func checkpoint(_ stage: String, _ url: URL) {
            let parent = url.deletingLastPathComponent().path
            let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
            print("BACKUP stage=\(stage) path=\(url.path) exists=\(fm.fileExists(atPath: url.path)) mode=\(mode?.intValue ?? -1) parentExists=\(fm.fileExists(atPath: parent)) parentWritable=\(fm.isWritableFile(atPath: parent)) wal=\(fm.fileExists(atPath: url.path + "-wal")) shm=\(fm.fileExists(atPath: url.path + "-shm"))")
        }
        let database = directory.appendingPathComponent("db.sqlite")
        checkpoint("initial-open", database)
        let store = try ClipStore(path: database.path)
        try store.capture([text("respaldo")], title: "Respaldo", text: "respaldo", source: "test")
        let url = directory.appendingPathComponent("backup.sqlite")
        try store.backup(to: url)
        checkpoint("backup-validated", url)
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try store.backup(to: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        // Reproduce the old two-opener sequence on a separate, synthetic file.
        let probe = directory.appendingPathComponent("wal-probe.sqlite")
        try original.write(to: probe)
        do {
            var native: OpaquePointer?
            let opened = cm_open(probe.path, &native)
            defer { if let native { sqlite3_close(native) } }
            XCTAssertEqual(opened, SQLITE_OK)
            checkpoint("legacy-readonly-before", probe)
            let legacy = cm_validate_file(probe.path)
            let live = cm_validate(native)
            print("BACKUP stage=legacy-comparison path=\(probe.path) cm_open=\(opened) cm_validate_file_READONLY=\(legacy) cm_validate_live=\(live)")
            XCTAssertEqual(live, SQLITE_OK)
        }
        // A backup must remain valid when only the main file is transferred,
        // including ordinary spaces, Unicode and URI punctuation in the filename.
        let standalone = directory.appendingPathComponent("standalone ñ # ?.sqlite")
        try original.write(to: standalone)
        checkpoint("standalone-open", standalone)
        let copied = try ClipStore(path: standalone.path)
        XCTAssertEqual(try copied.clips().count, 1)
        XCTAssertEqual(try copied.representations(copied.clips()[0].id), [text("respaldo")])
        checkpoint("standalone-passed", standalone)
        try store.capture([text("después")], title: "Después", text: "después", source: "test")
        checkpoint("merge-begin", url)
        XCTAssertEqual(try store.mergeBackup(url), 0)
        XCTAssertEqual(try store.clips().count, 2)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let corrupt = directory.appendingPathComponent("invalid.sqlite")
        try Data("not a database".utf8).write(to: corrupt)
        XCTAssertThrowsError(try store.mergeBackup(corrupt))
        XCTAssertThrowsError(try store.mergeBackup(directory.appendingPathComponent("missing.sqlite")))
        XCTAssertEqual(try store.clips().count, 2)
        checkpoint("merge-passed-invalid-refused", url)
    }
    func testNamedPasteboardOnlyCapturePauseExclusionsAndOwnWrites() throws {
        // Never use .general in tests. Named board is independent of the user's clipboard.
        let board = NSPasteboard(name: NSPasteboard.Name("MemoriaLocalTests." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let suite = "MemoriaLocalTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults); defaults.set(true, forKey: "captureEnabled")
        let store = try ClipStore(path: ":memory:")
        let monitor = ClipboardMonitor(store: store, preferences: prefs, pasteboard: board)
        monitor.start(); defer { monitor.stop() }
        let item = NSPasteboardItem()
        item.setString("Texto con ñ", forType: .string); item.setData(Data("<b>Texto con ñ</b>".utf8), forType: .html)
        board.clearContents(); board.writeObjects([item]); monitor.poll(source: "com.test.source")
        XCTAssertEqual(try store.clips().count, 1)
        XCTAssertEqual(try store.representations(store.clips()[0].id).count, 2)
        prefs.paused = true
        board.clearContents(); board.setString("No guardar pausa", forType: .string); monitor.poll(source: "com.test.source")
        XCTAssertEqual(try store.clips().count, 1)
        prefs.paused = false; defaults.set("com.test.source", forKey: "excluded")
        board.clearContents(); board.setString("No guardar excluida", forType: .string); monitor.poll(source: "com.test.source")
        XCTAssertEqual(try store.clips().count, 1)
        defaults.set("", forKey: "excluded")
        let secret = NSPasteboardItem(); secret.setString("sintético", forType: .string)
        secret.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.clearContents(); board.writeObjects([secret]); monitor.poll(source: "com.test.source")
        XCTAssertEqual(try store.clips().count, 1)
        try monitor.write([text("Pegado propio")]); monitor.poll(source: "com.test.source")
        XCTAssertEqual(try store.clips().count, 1)
        XCTAssertEqual(board.string(forType: .string), "Pegado propio")
    }
    func testPlainTextHTMLNeverLoadsRemoteContentAndTransforms() {
        let html = "<script>unsafe()</script><style>x</style><b>Hola &amp; adiós</b><img src='https://invalid.test/pixel'>"
        XCTAssertEqual(ClipboardMonitor.plainText([Representation(item: 0, type: NSPasteboard.PasteboardType.html.rawValue, data: Data(html.utf8))]), "Hola & adiós")
        XCTAssertEqual(TextTransform.trim.apply(" \nñ 👋 \n"), "ñ 👋")
        XCTAssertEqual(TextTransform.camel.apply("HOLA mundo prueba"), "holaMundoPrueba")
        XCTAssertEqual(TextTransform.upper.apply("mañana"), "MAÑANA")
    }
    func testCopyFallbackUsesNamedPasteboardWithoutAccessibilityOrEvents() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("MemoriaLocalFallback." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let suite = "MemoriaLocalFallback." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults)
        XCTAssertFalse(defaults.bool(forKey: "autoPaste"))
        let monitor = ClipboardMonitor(store: try ClipStore(path: ":memory:"), preferences: preferences, pasteboard: board)
        let paste = PasteCoordinator(monitor: monitor, preferences: preferences)
        var hidden = false; var message = ""
        paste.onMessage = { message = $0 }
        try paste.paste([text("Solo copiar ñ")], hide: { hidden = true })
        XCTAssertTrue(hidden); XCTAssertEqual(board.string(forType: .string), "Solo copiar ñ")
        XCTAssertTrue(message.contains("⌘V")); XCTAssertNil(paste.destination)
    }
    func testPanelFiltersUseActualStoreAndDoNotEnableCapture() throws {
        _ = NSApplication.shared
        let board = NSPasteboard(name: NSPasteboard.Name("MemoriaLocalUI." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let suite = "MemoriaLocalUI." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults); let store = try ClipStore(path: ":memory:")
        try store.capture([text("visible")], title: "Visible", text: "visible", source: "test")
        try store.capture([text("oculta")], title: "Oculta", text: "oculta", source: "test")
        let monitor = ClipboardMonitor(store: store, preferences: preferences, pasteboard: board)
        let paste = PasteCoordinator(monitor: monitor, preferences: preferences)
        let controller = HistoryController(store: store, preferences: preferences, monitor: monitor, paste: paste)
        defer { controller.panel.close() }
        controller.reloadGroups(); controller.reload()
        XCTAssertEqual(controller.table.numberOfRows, 2)
        controller.search.stringValue = "visible"; controller.reload()
        XCTAssertEqual(controller.table.numberOfRows, 1)
        XCTAssertEqual(controller.selection.first?.title, "Visible")
        XCTAssertFalse(preferences.enabled)
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(controller.table.tableColumns[1].width, 100)
    }
    func testUsagePersistsWithoutReorderingAndSurvivesRecapture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("usage.sqlite").path
        var id = ""
        do {
            let store = try ClipStore(path: path)
            id = try store.capture([text("older")], title: "Older", text: "older", source: "test", now: 10).id
            try store.capture([text("newer")], title: "Newer", text: "newer", source: "test", now: 20)
            XCTAssertTrue(try store.clips().allSatisfy { $0.usedAt == nil })
            try store.markUsed([id], reorder: false, now: 30)
            XCTAssertEqual(try store.clips().last?.id, id)
            XCTAssertNil(try store.clips().last?.lastUsed)
        }
        let reopened = try ClipStore(path: path)
        XCTAssertEqual(try reopened.clips().last?.usedAt, 30)
        XCTAssertEqual(ClipStore.initialSelection(in: try reopened.clips()), 1)
        let duplicate = try reopened.capture([text("older")], title: "Duplicate", text: "older", source: "test", now: 40)
        XCTAssertTrue(duplicate.duplicate); XCTAssertEqual(duplicate.id, id)
        XCTAssertEqual(try reopened.clips().first?.usedAt, 30)
        try reopened.markUsed([id], reorder: true, now: 50)
        XCTAssertEqual(try reopened.clips().first?.lastUsed, 50)
        XCTAssertEqual(try reopened.clips().first?.usedAt, 50)
    }
    func testLegacyUsageMigrationAndReadOnlyBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("legacy.sqlite")
        do {
            let store = try ClipStore(path: path.path)
            let id = try store.capture([text("legacy")], title: "Legacy", text: "legacy", source: "test", now: 1).id
            try store.run("UPDATE clips SET last_used=2 WHERE id=?", [id])
            try store.run("ALTER TABLE clips DROP COLUMN used_at")
            try store.run("PRAGMA user_version=1")
            try store.run("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        let before = try Data(contentsOf: path)
        XCTAssertEqual(cm_validate_file(path.path), SQLITE_OK)
        XCTAssertEqual(try Data(contentsOf: path), before)
        let target = try ClipStore(path: ":memory:")
        XCTAssertEqual(try target.mergeBackup(path), 1)
        XCTAssertEqual(try Data(contentsOf: path), before)
        let migrated = try ClipStore(path: path.path)
        XCTAssertEqual(try migrated.run("PRAGMA user_version").first?["user_version"] as? Int, 2)
        XCTAssertEqual(try migrated.clips().first?.usedAt, 2)
        XCTAssertEqual(try migrated.representations(migrated.clips()[0].id), [text("legacy")])
    }
    func testInitialSelectionPolicyNewCaptureRecaptureAndRemovedItem() throws {
        let store = try ClipStore(path: ":memory:")
        XCTAssertNil(ClipStore.initialSelection(in: []))
        let older = try store.capture([text("a")], title: "A", text: "a", source: "test", now: 10).id
        let newer = try store.capture([text("b")], title: "B", text: "b", source: "test", now: 20).id
        func selected() throws -> String? {
            let clips = try store.clips()
            return ClipStore.initialSelection(in: clips).map { clips[$0].id }
        }
        XCTAssertEqual(try selected(), newer) // No usage yet, but there are clips.
        try store.markUsed([older], reorder: false, now: 30)
        XCTAssertEqual(try selected(), older) // Not the first displayed row.
        var sticky = try store.clips()[0]; sticky.sticky = 1; try store.metadata(sticky)
        XCTAssertEqual(try selected(), older) // Pinning does not change usage.
        try store.capture([text("b")], title: "B", text: "b", source: "test", now: 31)
        XCTAssertEqual(try selected(), newer) // Deduplication is a new capture.
        try store.markUsed([older], reorder: false, now: 31)
        XCTAssertEqual(try selected(), older) // Equal timestamps are not newer.
        try store.trash([older]); XCTAssertEqual(try selected(), newer)
        try store.trash([newer]); XCTAssertNil(try selected())
    }
    private func withHistory(_ body: (HistoryController, NSPasteboard) throws -> Void) throws {
        _ = NSApplication.shared
        let board = NSPasteboard(name: NSPasteboard.Name("MemoriaLocalFocus." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let suite = "MemoriaLocalFocus." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults); defaults.set(false, forKey: "reorder")
        let store = try ClipStore(path: ":memory:")
        let monitor = ClipboardMonitor(store: store, preferences: preferences, pasteboard: board)
        let controller = HistoryController(store: store, preferences: preferences, monitor: monitor,
                                           paste: PasteCoordinator(monitor: monitor, preferences: preferences))
        defer { controller.panel.close() }
        try body(controller, board)
    }
    private func key(_ controller: HistoryController, _ code: UInt16, _ characters: String,
                     flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: controller.panel.windowNumber, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: code))
    }
    func testPanelOpeningFocusTypeToSearchAndTab() throws {
        try withHistory { controller, _ in
            controller.open()
            XCTAssertTrue(controller.panel.firstResponder === controller.search.currentEditor())
            let store = controller.store
            let older = try store.capture([text("visible")], title: "Visible", text: "visible", source: "test", now: 10).id
            let newer = try store.capture([text("other")], title: "Other", text: "other", source: "test", now: 20).id
            try store.markUsed([older], reorder: false, now: 30)
            controller.search.stringValue = "stale"; controller.favoriteButton.state = .on
            controller.open()
            XCTAssertTrue(controller.panel.firstResponder === controller.table)
            XCTAssertEqual(controller.selection.map(\.id), [older])
            XCTAssertEqual(controller.clips.count, 2)
            XCTAssertTrue(controller.table.onKey?(try key(controller, 9, "v")) == true)
            XCTAssertTrue(controller.panel.firstResponder === controller.search.currentEditor())
            XCTAssertEqual(controller.search.stringValue, "v")
            XCTAssertEqual(controller.clips.map(\.id), [older])
            controller.open()
            XCTAssertTrue(controller.table.onKey?(try key(controller, 48, "\t")) == true)
            XCTAssertTrue(controller.panel.firstResponder === controller.search.currentEditor())
            try store.capture([text("other")], title: "Other", text: "other", source: "test", now: 40)
            controller.open()
            XCTAssertEqual(controller.selection.map(\.id), [newer])
            XCTAssertTrue(controller.panel.firstResponder === controller.table)
            XCTAssertFalse(controller.table.onKey?(try key(controller, 125, "\u{F701}")) ?? true)
            XCTAssertNil(try store.clips().first { $0.id == newer }?.usedAt) // Focus/arrows are not usage.
            XCTAssertTrue(controller.table.onKey?(try key(controller, 53, "\u{1B}")) == true)
            XCTAssertFalse(controller.panel.isVisible)
        }
    }
    func testClickMarksAndRefreshesRowWithoutPastingOrReordering() throws {
        try withHistory { controller, board in
            let store = controller.store
            let older = try store.capture([text("a")], title: "A", text: "a", source: "test", now: 10).id
            try store.capture([text("b")], title: "B", text: "b", source: "test", now: 20)
            controller.open(); controller.panel.contentView?.layoutSubtreeIfNeeded()
            let view = try XCTUnwrap(controller.table.rowView(atRow: 1, makeIfNecessary: true) as? UsedHistoryRow)
            XCTAssertFalse(view.used)
            let count = board.changeCount
            controller.useClickedRow(1)
            XCTAssertTrue(view.used); XCTAssertTrue(view.needsDisplay)
            XCTAssertEqual(board.changeCount, count)
            XCTAssertEqual(controller.clips[1].id, older)
            XCTAssertNotNil(try store.clips().first { $0.id == older }?.usedAt)
            XCTAssertNil(try store.clips().first?.usedAt)
            controller.useClickedRow(-1) // Empty area is not usage.
        }
    }
    func testUsedStripeDrawsBlueOnlyAtLeftEdge() throws {
        _ = NSApplication.shared
        let row = UsedHistoryRow(frame: NSRect(x: 0, y: 0, width: 120, height: 49))
        let blue = try XCTUnwrap(NSColor.systemBlue.usingColorSpace(.deviceRGB))
        for used in [false, true] {
            row.used = used
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 49,
                                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            row.draw(row.bounds)
            NSGraphicsContext.restoreGraphicsState()
            for y in [5, 24, 43] {
                let pixel = try XCTUnwrap(bitmap.colorAt(x: 1, y: y)?.usingColorSpace(.deviceRGB))
                let isBlue = abs(pixel.redComponent - blue.redComponent) < 0.02 &&
                    abs(pixel.greenComponent - blue.greenComponent) < 0.02 && abs(pixel.blueComponent - blue.blueComponent) < 0.02
                XCTAssertEqual(isBlue, used)
            }
            // Outside the 4 pt stripe, this unselected row must not paint system blue.
            let outside = try XCTUnwrap(bitmap.colorAt(x: 6, y: 24)?.usingColorSpace(.deviceRGB))
            XCTAssertTrue(outside.alphaComponent < 0.1 || abs(outside.redComponent - blue.redComponent) > 0.02 ||
                          abs(outside.greenComponent - blue.greenComponent) > 0.02 || abs(outside.blueComponent - blue.blueComponent) > 0.02)
        }
    }
    func testAllCopyPasteEntryPointsMarkUsed() throws {
        try withHistory { controller, board in
            let store = controller.store
            let id = try store.capture([text("hello")], title: "Hello", text: "hello", source: "test").id
            _ = try store.buffer(1, clip: id)
            for command in ["copy", "paste", "plain", "transform:MAYÚSCULAS", "bufferPaste:1", "enter", "shiftEnter", "option1", "doubleClick", "commandC"] {
                try store.run("UPDATE clips SET used_at=NULL,last_used=NULL")
                controller.open()
                switch command {
                case "enter", "shiftEnter":
                    controller.table.keyDown(with: try key(controller, 36, "\r", flags: command == "shiftEnter" ? .shift : []))
                case "option1": controller.table.keyDown(with: try key(controller, 18, "1", flags: .option))
                case "doubleClick":
                    XCTAssertTrue(controller.table.sendAction(try XCTUnwrap(controller.table.doubleAction), to: controller.table.target))
                case "commandC":
                    XCTAssertTrue(controller.table.performKeyEquivalent(with: try key(controller, 8, "c", flags: .command)))
                default: controller.commandAction(command)
                }
                XCTAssertNotNil(try store.clips().first?.usedAt, command)
                XCTAssertNil(try store.clips().first?.lastUsed, command) // Reorder is disabled.
                XCTAssertEqual(board.string(forType: .string), command.hasPrefix("transform:") ? "HELLO" : "hello", command)
            }
            try store.run("UPDATE clips SET used_at=NULL")
            controller.reload(); controller.table.deselectAll(nil); controller.copySelection()
            XCTAssertNil(try store.clips().first?.usedAt) // Failed/empty copy must not mark.
        }
    }
    func testOversizeAndDuplicateRepresentationRejectBeforeWrite() throws {
        let store = try ClipStore(path: ":memory:")
        XCTAssertThrowsError(try store.capture([text("a"), text("b")], title: "bad", text: "bad", source: "test"))
        XCTAssertTrue(try store.clips().isEmpty)
        XCTAssertThrowsError(try ClipStore.validate([Representation(item: -1, type: "public.png", data: Data())]))
    }
}
