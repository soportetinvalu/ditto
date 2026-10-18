// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import AppKit
import Carbon
import ClipCore
import Security
@testable import NexClip

final class NexClipTests: XCTestCase {
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
        let suite = "NexClip-shortcut-tests-" + UUID().uuidString
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
        let suite = "NexClip-shortcut-registration-" + UUID().uuidString
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
        let board = NSPasteboard(name: NSPasteboard.Name("NexClipTests." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let suite = "NexClipTests." + UUID().uuidString
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
    func testAccessibilityAlertOnlyForUntrustedProcessAndExplainsUpdateRecovery() throws {
        _ = NSApplication.shared
        XCTAssertNil(PasteCoordinator.accessibilityAlert(isTrusted: true))
        let alert = try XCTUnwrap(PasteCoordinator.accessibilityAlert(isTrusted: false))
        XCTAssertEqual(alert.messageText, "Permitir el pegado automático")
        XCTAssertEqual(alert.buttons.map(\.title), ["Solicitar permiso", "Solo copiar", "Copiar diagnóstico", "Abrir Accesibilidad"])
        XCTAssertTrue(alert.informativeText.contains("aviso oficial de macOS"))
        XCTAssertTrue(alert.informativeText.contains("Restablecer permiso de Accesibilidad en Ajustes de NexClip"))
        XCTAssertFalse(alert.informativeText.contains("vuelve a añadirla"))
        XCTAssertTrue(alert.informativeText.contains("pegar manualmente"))
        XCTAssertEqual(PasteCoordinator.accessibilitySettingsURL?.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }
    func testTranslocatedAccessibilityAdviceUsesRunningBundleAndNeverOverridesTrust() throws {
        _ = NSApplication.shared
        let translocated = URL(fileURLWithPath: "/private/var/folders/xx/T/AppTranslocation/UUID/d/NexClip.app")
        let installed = URL(fileURLWithPath: "/Applications/NexClip.app")
        XCTAssertTrue(PasteCoordinator.isTranslocated(bundleURL: translocated))
        XCTAssertFalse(PasteCoordinator.isTranslocated(bundleURL: installed))
        XCTAssertFalse(PasteCoordinator.isTranslocated(bundleURL: URL(fileURLWithPath: "/Downloads/AppTranslocation-notes/NexClip.app")))
        XCTAssertNil(PasteCoordinator.accessibilityAlert(isTrusted: true, bundleURL: translocated))
        let alert = try XCTUnwrap(PasteCoordinator.accessibilityAlert(isTrusted: false, bundleURL: translocated))
        XCTAssertTrue(alert.informativeText.contains("ruta de App Translocation"))
        XCTAssertTrue(alert.informativeText.contains("a Aplicaciones con Finder"))
        XCTAssertTrue(alert.informativeText.contains("menú Salir"))
        XCTAssertTrue(alert.informativeText.contains("Ruta de esta copia: \(translocated.path)"))
        let regular = try XCTUnwrap(PasteCoordinator.accessibilityAlert(isTrusted: false, bundleURL: installed))
        XCTAssertFalse(regular.informativeText.contains("ruta de App Translocation"))
        XCTAssertTrue(regular.informativeText.contains("Ruta de esta copia: \(installed.path)"))
    }
    func testAccessibilityWaitDoesNotPromptWhenAlreadyTrustedOrOnPassiveCheck() {
        var prompts = 0
        let wait = AccessibilityPermissionWait(isTrusted: { true }, prompt: { prompts += 1 })
        wait.check(onForeground: true)
        XCTAssertEqual(wait.phase, .idle); XCTAssertEqual(prompts, 0)
        wait.request()
        XCTAssertEqual(wait.phase, .granted); XCTAssertEqual(prompts, 0)
    }
    func testAccessibilityWaitPromptIsNotConsentAndGrantIsObservedOnce() {
        var trusted = false; var prompts = 0; var reads = 0
        let wait = AccessibilityPermissionWait(isTrusted: { reads += 1; return trusted }, prompt: { prompts += 1 })
        wait.request()
        XCTAssertEqual(prompts, 1); XCTAssertEqual(wait.phase, .waiting)
        wait.check(); XCTAssertEqual(wait.phase, .waiting)
        trusted = true; wait.check()
        XCTAssertEqual(wait.phase, .granted)
        let finalReads = reads
        wait.check(); wait.check(onForeground: true)
        XCTAssertEqual(reads, finalReads); XCTAssertEqual(prompts, 1)
    }
    func testAccessibilityWaitStopsAtExactlySixtySecondsAndRetryRestartsClock() {
        var now: TimeInterval = 100; var reads = 0; var prompts = 0
        let wait = AccessibilityPermissionWait(clock: { now }, isTrusted: { reads += 1; return false }, prompt: { prompts += 1 })
        wait.request()
        now = 159.999; wait.check(); XCTAssertEqual(wait.phase, .waiting)
        now = 160; wait.check(); XCTAssertEqual(wait.phase, .timedOut)
        let finalReads = reads
        now = 200; wait.check(); XCTAssertEqual(reads, finalReads)
        wait.request(); XCTAssertEqual(wait.phase, .waiting); XCTAssertEqual(prompts, 2)
        now = 259.999; wait.check(); XCTAssertEqual(wait.phase, .waiting)
        now = 260; wait.check(); XCTAssertEqual(wait.phase, .timedOut)
    }
    func testAccessibilityWaitForegroundRecognizesGrantEvenAfterTimeoutWithoutReprompting() {
        var now: TimeInterval = 0; var trusted = false; var prompts = 0
        let wait = AccessibilityPermissionWait(clock: { now }, isTrusted: { trusted }, prompt: { prompts += 1 })
        wait.request(); now = 60; wait.check()
        XCTAssertEqual(wait.phase, .timedOut)
        trusted = true; wait.check(); XCTAssertEqual(wait.phase, .timedOut)
        wait.check(onForeground: true)
        XCTAssertEqual(wait.phase, .granted); XCTAssertEqual(prompts, 1)
    }
    func testAccessibilityWaitCancellationCannotGrantOrRequestFromPolling() {
        var trusted = false; var prompts = 0
        let wait = AccessibilityPermissionWait(isTrusted: { trusted }, prompt: { prompts += 1 })
        wait.request(); wait.cancel(); trusted = true
        wait.check(); wait.check(onForeground: true)
        XCTAssertEqual(wait.phase, .cancelled); XCTAssertEqual(prompts, 1)
        wait.request(); XCTAssertEqual(wait.phase, .granted); XCTAssertEqual(prompts, 1)
    }
    func testDuplicateAccessibilityRequestCannotPromptAgainOrExtendDeadline() {
        var now: TimeInterval = 0; var prompts = 0
        let wait = AccessibilityPermissionWait(clock: { now }, isTrusted: { false }, prompt: { prompts += 1 })
        wait.request(); XCTAssertTrue(wait.isWaiting)
        now = 59; wait.request(); wait.request()
        XCTAssertEqual(prompts, 1)
        now = 60; wait.check()
        XCTAssertEqual(wait.phase, .timedOut); XCTAssertFalse(wait.isWaiting)
        wait.request(); XCTAssertEqual(prompts, 2)
    }
    func testTargetedResetHasFixedArgumentsAndFailureNeverMeansSuccess() {
        XCTAssertEqual(AccessibilityReset.executable.path, "/usr/bin/tccutil")
        XCTAssertEqual(AccessibilityReset.arguments, ["reset", "Accessibility", "com.nexclip.app"])
        XCTAssertTrue(AccessibilityResetResult(exitCode: 0, output: "reset").succeeded)
        XCTAssertFalse(AccessibilityResetResult(exitCode: 1, output: "denied").succeeded)
        XCTAssertFalse(AccessibilityResetResult(exitCode: -1, output: "launch failed").succeeded)
        XCTAssertTrue(AccessibilityResetResult(exitCode: 1, output: "denied").summary.contains("exit=1"))
    }
    func testPermissionControlsDisableAndPanelLowersWithoutReactivation() throws {
        _ = NSApplication.shared
        let store = try ClipStore(path: ":memory:")
        let preferences = Preferences()
        let board = NSPasteboard(name: NSPasteboard.Name("NexClipWindow." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(store: store, preferences: preferences, pasteboard: board)
        let paste = PasteCoordinator(monitor: monitor, preferences: preferences)
        let history = HistoryController(store: store, preferences: preferences, monitor: monitor, paste: paste)
        XCTAssertEqual(history.panel.level, .floating)
        XCTAssertTrue(history.panel.hidesOnDeactivate)
        history.hideForPermission()
        XCTAssertFalse(history.panel.isVisible); XCTAssertEqual(history.panel.level, .normal)
        history.accessibilityMessage = "Esperando permiso de macOS…"; history.reload()
        XCTAssertEqual(history.information.stringValue, "Esperando permiso de macOS…")
        let settings = SettingsController(preferences: preferences, store: store)
        settings.updatePermissionState(busy: true, message: "Esperando permiso de macOS…")
        XCTAssertTrue(settings.permissionBusy); XCTAssertFalse(settings.permissionActionsEnabled)
        settings.updatePermissionState(busy: false, message: "Permiso concedido")
        XCTAssertFalse(settings.permissionBusy); XCTAssertTrue(settings.permissionActionsEnabled)
    }
    func testTCCReadFailureIsNotReportedAsMissingRowAndNeverCreatesDatabase() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let report = AccessibilityTCCInspection.inspect(path: path, identifier: "test.own", bundlePath: "/test.app", executablePath: "/test.app/run").joined(separator: "\n")
        XCTAssertTrue(report.contains("TCC no legible")); XCTAssertFalse(report.contains("0 filas"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(AccessibilityTCCInspection.requirementReport(Data([0, 1, 2])).contains("no decodificable"))
    }
    func testTCCReadOnlyQueryScopesServiceClientAndPathAndPreservesBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("synthetic.sqlite").path
        do {
            let store = try ClipStore(path: path)
            try store.run("CREATE TABLE access(service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER, csreq BLOB)")
            for (service, client, type, auth) in [("kTCCServiceAccessibility", "test.own", 0, 2),
                ("kTCCServiceAccessibility", "/test.app/run", 1, 0),
                ("kTCCServiceAccessibility", "other.secret", 0, 2),
                ("kTCCServiceCamera", "test.own", 0, 2),
                ("kTCCServiceAccessibility", "test.own", 1, 2)] {
                try store.run("INSERT INTO access VALUES(?,?,?,?,NULL)", [service, client, type, auth])
            }
        }
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let report = AccessibilityTCCInspection.inspect(path: path, identifier: "test.own", bundlePath: "/test.app", executablePath: "/test.app/run").joined(separator: "\n")
        XCTAssertTrue(report.contains("2 filas propias")); XCTAssertTrue(report.contains("auth_value=2"))
        XCTAssertTrue(report.contains("auth_value=0")); XCTAssertTrue(report.contains("csreq=NULL"))
        XCTAssertFalse(report.contains("other.secret")); XCTAssertFalse(report.contains("Camera"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        let empty = AccessibilityTCCInspection.inspect(path: path, identifier: "no.client", bundlePath: "/none", executablePath: "/none/run").joined(separator: "\n")
        XCTAssertTrue(empty.contains("0 filas propias")); XCTAssertFalse(empty.contains("TCC no legible"))
    }
    func testTCCRequirementEvaluationSeparatesMismatchFromUndecodable() throws {
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString("identifier \"invalid.test.not-this-process\"" as CFString, SecCSFlags(rawValue: 0), &requirement), errSecSuccess)
        var data: CFData?
        XCTAssertEqual(SecRequirementCopyData(try XCTUnwrap(requirement), SecCSFlags(rawValue: 0), &data), errSecSuccess)
        let report = AccessibilityTCCInspection.requirementReport(try XCTUnwrap(data) as Data)
        XCTAssertTrue(report.contains("invalid.test.not-this-process"))
        XCTAssertTrue(report.contains("csreq frente a este proceso: \(errSecCSReqFailed)"), report)
        XCTAssertFalse(report.contains("no decodificable"))
        var code: SecCode?; var disk: SecStaticCode?; var own: SecRequirement?
        XCTAssertEqual(SecCodeCopySelf(SecCSFlags(rawValue: 0), &code), errSecSuccess)
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(code), SecCSFlags(rawValue: 0), &disk), errSecSuccess)
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(try XCTUnwrap(disk), SecCSFlags(rawValue: 0), &own), errSecSuccess)
        var ownData: CFData?
        XCTAssertEqual(SecRequirementCopyData(try XCTUnwrap(own), SecCSFlags(rawValue: 0), &ownData), errSecSuccess)
        XCTAssertTrue(AccessibilityTCCInspection.requirementReport(try XCTUnwrap(ownData) as Data).contains("csreq frente a este proceso: 0"))
    }
    func testAccessibilityPromptDiagnosticRecordsInvocationAndUTCWithoutClaimingConsent() {
        let initialCount = AccessibilityDiagnostics.promptInvocationCount
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        AccessibilityDiagnostics.recordPrompt(at: date)
        XCTAssertEqual(AccessibilityDiagnostics.promptInvocationCount, initialCount + 1)
        XCTAssertEqual(AccessibilityDiagnostics.lastPromptAt, date)
        let summary = AccessibilityDiagnostics.promptSummary(count: 1, lastAt: date)
        XCTAssertTrue(summary.contains("prompt=true invocado en este proceso: true; llamadas: 1"))
        XCTAssertTrue(summary.contains("2023-11-14T22:13:20Z"))
        let never = AccessibilityDiagnostics.promptSummary(count: 0, lastAt: nil)
        XCTAssertTrue(never.contains("proceso: false; llamadas: 0")); XCTAssertTrue(never.contains("nunca"))
        let before = AccessibilityDiagnostics.promptInvocationCount
        XCTAssertTrue(AccessibilityDiagnostics.report().contains(summary.replacingOccurrences(of: "llamadas: 1", with: "llamadas: \(before)")))
        XCTAssertEqual(AccessibilityDiagnostics.promptInvocationCount, before)
    }
    func testAccessibilityDiagnosticReportIsLocalAndDoesNotPrompt() {
        let report = AccessibilityDiagnostics.report()
        for key in ["macOS:", "versión:", "commit:", "bundle:", "ejecutable:", "pid:", "bundle id:",
                    "AXIsProcessTrusted():", "kAXTrustedCheckOptionPrompt: prompt=true invocado en este proceso:", "quarantine (bundle):",
                    "instancias con el mismo bundle id:", "Rosetta:", "SecCodeCopySelf:"] {
            XCTAssertTrue(report.contains(key), "Falta \(key)")
        }
        XCTAssertTrue(AccessibilityDiagnostics.logURL.path.hasSuffix("Library/Logs/NexClip/diagnostico-accesibilidad.txt"))
    }
    func testDiagnosticCopySavesPrivateLogAndNeverCapturesItEvenAcrossPause() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("NexClipDiagnostic." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let suite = "NexClipDiagnostic." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "captureEnabled")
        let preferences = Preferences(defaults)
        let store = try ClipStore(path: ":memory:")
        let monitor = ClipboardMonitor(store: store, preferences: preferences, pasteboard: board)
        let secret = "Contenido sintético que no debe incluirse en el diagnóstico"
        _ = try store.capture([text(secret)], title: secret, text: secret, source: "com.test.source")
        board.clearContents(); board.setString(secret, forType: .string)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("diagnostico.txt")
        let report = AccessibilityDiagnostics.report()
        XCTAssertFalse(report.contains(secret))
        for paused in [false, true] {
            preferences.paused = paused
            XCTAssertEqual(try AccessibilityDiagnostics.copy(report, monitor: monitor, destination: file), file)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), report)
            XCTAssertEqual(board.string(forType: .string), report)
            monitor.poll(source: "com.test.source")
            preferences.paused = false; monitor.poll(source: "com.test.source")
            XCTAssertEqual(try store.clips().count, 1)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        board.clearContents(); board.setString("Nueva copia legítima", forType: .string)
        monitor.poll(source: "com.test.source")
        XCTAssertEqual(try store.clips().count, 2)
    }
    func testDiagnosticSaveFailureDoesNotReplaceClipboard() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("NexClipDiagnosticFailure." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(store: try ClipStore(path: ":memory:"), preferences: Preferences(), pasteboard: board)
        board.clearContents(); board.setString("Conservar copia sintética", forType: .string)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try AccessibilityDiagnostics.copy("Diagnóstico", monitor: monitor, destination: file.appendingPathComponent("imposible.txt")))
        XCTAssertEqual(board.string(forType: .string), "Conservar copia sintética")
    }
    func testCopyFallbackUsesNamedPasteboardWithoutAccessibilityOrEvents() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("NexClipFallback." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let suite = "NexClipFallback." + UUID().uuidString
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
        let board = NSPasteboard(name: NSPasteboard.Name("NexClipUI." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let suite = "NexClipUI." + UUID().uuidString
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
        let board = NSPasteboard(name: NSPasteboard.Name("NexClipFocus." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let suite = "NexClipFocus." + UUID().uuidString
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
    func testSecureInputNoticeIsSampledBeforeOpeningAndSurvivesReload() throws {
        try withHistory { controller, board in
            controller.hide()
            var samples = 0
            controller.secureInputEnabled = {
                samples += 1
                XCTAssertFalse(controller.panel.isVisible)
                return true
            }
            let count = board.changeCount
            controller.open()
            XCTAssertEqual(samples, 1)
            XCTAssertTrue(controller.panel.isVisible)
            XCTAssertFalse(controller.secureInputNotice.isHidden)
            XCTAssertEqual(controller.secureInputNotice.stringValue, HistoryController.secureInputMessage)
            controller.message("Otro mensaje")
            controller.search.stringValue = "sin resultados"; controller.reload()
            XCTAssertEqual(samples, 1) // Do not lose the snapshot when focus disables secure input.
            XCTAssertFalse(controller.secureInputNotice.isHidden)
            XCTAssertEqual(controller.secureInputNotice.stringValue, HistoryController.secureInputMessage)
            XCTAssertEqual(board.changeCount, count)
            XCTAssertFalse(controller.preferences.enabled)
        }
    }
    func testSecureInputNoticeClearsOnNextUnprotectedOpening() throws {
        try withHistory { controller, _ in
            var secure = false
            controller.secureInputEnabled = { secure }
            for value in [false, true, false, true] {
                secure = value
                controller.open()
                XCTAssertTrue(controller.panel.isVisible)
                XCTAssertEqual(controller.secureInputNotice.isHidden, !value)
                XCTAssertEqual(controller.secureInputNotice.stringValue, value ? HistoryController.secureInputMessage : "")
            }
        }
    }
    func testPanelCanAppearAcrossDesktopsAndAlongsideFullScreenApps() throws {
        try withHistory { controller, _ in
            XCTAssertTrue(controller.panel.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(controller.panel.collectionBehavior.contains(.fullScreenAuxiliary))
            XCTAssertTrue(controller.panel.hidesOnDeactivate)
            XCTAssertEqual(controller.panel.level, .floating)
            // The same open() used by the menu/icon must not depend on shortcut registration.
            controller.secureInputEnabled = { true }
            controller.open()
            XCTAssertTrue(controller.panel.isVisible)
            XCTAssertFalse(controller.secureInputNotice.isHidden)
        }
    }
    func testCarbonRegistrationAndHandlerWorkWithProcessSecureInputEnabled() throws {
        _ = NSApplication.shared
        let rc = EnableSecureEventInput()
        XCTAssertEqual(rc, noErr)
        guard rc == noErr else { return }
        defer { XCTAssertEqual(DisableSecureEventInput(), noErr) }
        XCTAssertTrue(IsSecureEventInputEnabled())
        let shortcut = GlobalShortcut()
        var deliveries = 0
        shortcut.action = { deliveries += 1 }
        try shortcut.register(.init(keyCode: 79, modifiers: UInt32(cmdKey | controlKey | optionKey)))
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                   GetCurrentEventTime(), UInt32(kEventAttributeUserEvent), &event), noErr)
        let created = try XCTUnwrap(event)
        defer { ReleaseEvent(created) }
        // Exercise real Carbon dispatch, NOT a physical shortcut from a different app.
        XCTAssertEqual(deliveries, 0)
        XCTAssertEqual(SendEventToEventTarget(created, GetApplicationEventTarget()), noErr)
        XCTAssertEqual(deliveries, 1)
        XCTAssertTrue(IsSecureEventInputEnabled())
        withExtendedLifetime(shortcut) {}
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
