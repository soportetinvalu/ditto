// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Foundation
import ClipCore
@testable import NexClip

final class LegacyMigrationTests: XCTestCase {
    private func fixture(_ body: (URL, UserDefaults, String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let domain = "NexClip-migration-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        try body(root, defaults, domain)
    }
    private func seed(_ root: URL) throws -> URL {
        let source = root.appendingPathComponent(LegacyMigration.legacyDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (name, text) in [("history.sqlite", "database"), ("history.sqlite-wal", "wal"), ("history.sqlite-shm", "shm"),
                             ("respaldo.sqlite", "manual-backup") ] {
            try Data(text.utf8).write(to: source.appendingPathComponent(name))
        }
        return source
    }
    func testMigrationCopiesDatabaseSidecarsAndRelevantPreferences() throws {
        try fixture { root, defaults, domain in
            let source = try seed(root)
            let values: [String: Any] = ["captureEnabled": true, "autoPaste": true, "hotKey": 9,
                                        "hotModifiers": 4608, "excluded": "secret.app", "allowed": "editor.app",
                                        "days": 42, "separator": "\t", "unrelated": "not imported"]
            // Registered defaults must not conceal real legacy preferences.
            defaults.register(defaults: ["captureEnabled": false, "autoPaste": false])
            let timestamp = "2023-11-14T22:13:20Z"
            let result = try LegacyMigration.run(applicationSupport: root, defaults: defaults, destinationDomain: domain,
                legacyPreferences: values, at: Date(timeIntervalSince1970: 1700000000), log: root.appendingPathComponent("log/migracion.log"))
            XCTAssertEqual(result, "migrado desde Memoria Local el " + timestamp)
            let target = root.appendingPathComponent("NexClip")
            for name in ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm"] {
                XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(name)), try Data(contentsOf: target.appendingPathComponent(name)))
            }
            XCTAssertTrue(defaults.bool(forKey: "captureEnabled")); XCTAssertTrue(defaults.bool(forKey: "autoPaste"))
            XCTAssertEqual(defaults.integer(forKey: "hotKey"), 9); XCTAssertEqual(defaults.integer(forKey: "hotModifiers"), 4608)
            XCTAssertEqual(defaults.string(forKey: "excluded"), "secret.app"); XCTAssertEqual(defaults.string(forKey: "allowed"), "editor.app")
            XCTAssertEqual(defaults.integer(forKey: "days"), 42); XCTAssertEqual(defaults.string(forKey: "separator"), "\t")
            XCTAssertNil(defaults.object(forKey: "unrelated"))
            XCTAssertEqual(LegacyMigration.diagnostic(defaults: defaults), result)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("log/migracion.log"), encoding: .utf8), result! + "\n")
        }
    }
    func testMigrationDoesNotOverwriteExistingNexClipDataOrPreferences() throws {
        try fixture { root, defaults, domain in
            _ = try seed(root)
            let target = root.appendingPathComponent("NexClip")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let database = target.appendingPathComponent("history.sqlite")
            try Data("new history".utf8).write(to: database)
            defaults.set(false, forKey: "autoPaste")
            XCTAssertNil(try LegacyMigration.run(applicationSupport: root, defaults: defaults, destinationDomain: domain,
                legacyPreferences: ["autoPaste": true], log: root.appendingPathComponent("migration.log")))
            XCTAssertEqual(try String(contentsOf: database, encoding: .utf8), "new history")
            XCTAssertFalse(defaults.bool(forKey: "autoPaste")); XCTAssertNil(defaults.string(forKey: LegacyMigration.dateKey))
        }
    }
    func testMigrationWithoutSourceIsNoOp() throws {
        try fixture { root, defaults, domain in
            XCTAssertNil(try LegacyMigration.run(applicationSupport: root, defaults: defaults, destinationDomain: domain,
                legacyPreferences: ["captureEnabled": true], log: root.appendingPathComponent("migration.log")))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("NexClip/history.sqlite").path))
            XCTAssertNil(defaults.object(forKey: "captureEnabled"))
        }
    }
    func testMigrationLeavesEntireSourceAndBackupsIntactAndIsIdempotent() throws {
        try fixture { root, defaults, domain in
            let source = try seed(root)
            let names = try FileManager.default.contentsOfDirectory(atPath: source.path).sorted()
            let before = try names.map { try Data(contentsOf: source.appendingPathComponent($0)) }
            let log = root.appendingPathComponent("migration.log")
            _ = try LegacyMigration.run(applicationSupport: root, defaults: defaults, destinationDomain: domain,
                legacyPreferences: ["paused": true], log: log)
            XCTAssertNil(try LegacyMigration.run(applicationSupport: root, defaults: defaults, destinationDomain: domain,
                legacyPreferences: ["paused": false], log: log))
            XCTAssertTrue(defaults.bool(forKey: "paused"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path).sorted(), names)
            XCTAssertEqual(try names.map { try Data(contentsOf: source.appendingPathComponent($0)) }, before)
        }
    }
    func testMigrationRefusesRunningLegacyAppAndPreservesNewExplicitPreference() throws {
        try fixture { root, defaults, domain in
            _ = try seed(root)
            XCTAssertThrowsError(try LegacyMigration.run(applicationSupport: root, defaults: defaults, destinationDomain: domain,
                legacyPreferences: [:], legacyIsRunning: true, log: root.appendingPathComponent("log")))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("NexClip/history.sqlite").path))
            defaults.set(false, forKey: "captureEnabled")
            _ = try LegacyMigration.run(applicationSupport: root, defaults: defaults, destinationDomain: domain,
                legacyPreferences: ["captureEnabled": true, "autoPaste": true], log: root.appendingPathComponent("log"))
            XCTAssertFalse(defaults.bool(forKey: "captureEnabled")); XCTAssertTrue(defaults.bool(forKey: "autoPaste"))
        }
    }
    func testMigrationRecoversPreferencesFromReceiptWithoutReimportingDatabase() throws {
        try fixture { root, defaults, domain in
            _ = try seed(root)
            let log = root.appendingPathComponent("log")
            let message = try LegacyMigration.run(applicationSupport: root, defaults: defaults, destinationDomain: domain,
                legacyPreferences: ["autoPaste": true], log: log)
            defaults.removePersistentDomain(forName: domain) // process stopped before preferences were durable
            let database = root.appendingPathComponent("NexClip/history.sqlite")
            try Data("newer database".utf8).write(to: database)
            XCTAssertEqual(try LegacyMigration.run(applicationSupport: root, defaults: defaults, destinationDomain: domain,
                legacyPreferences: ["autoPaste": false], log: log), message)
            XCTAssertTrue(defaults.bool(forKey: "autoPaste"))
            XCTAssertEqual(try String(contentsOf: database, encoding: .utf8), "newer database")
        }
    }
    func testMigrationSQLiteWALSnapshotIsReadableWithoutTouchingSource() throws {
        try fixture { root, defaults, domain in
            let live = root.appendingPathComponent("live.sqlite")
            var connection: OpaquePointer?
            XCTAssertEqual(sqlite3_open(live.path, &connection), SQLITE_OK)
            guard let connection else { return XCTFail("No SQLite connection") }
            defer { sqlite3_close(connection) }
            XCTAssertEqual(sqlite3_exec(connection, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE witness(value TEXT); INSERT INTO witness VALUES('copied WAL');", nil, nil, nil), SQLITE_OK)
            let source = root.appendingPathComponent(LegacyMigration.legacyDirectory)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            // A detached snapshot emulates a stopped legacy app with uncheckpointed WAL.
            var original = [String: Data]()
            for suffix in ["", "-wal", "-shm"] {
                let data = try Data(contentsOf: URL(fileURLWithPath: live.path + suffix))
                original[suffix] = data
                try data.write(to: source.appendingPathComponent("history.sqlite" + suffix))
            }
            _ = try LegacyMigration.run(applicationSupport: root, defaults: defaults, destinationDomain: domain,
                legacyPreferences: [:], log: root.appendingPathComponent("log"))
            var migrated: OpaquePointer?
            XCTAssertEqual(sqlite3_open(root.appendingPathComponent("NexClip/history.sqlite").path, &migrated), SQLITE_OK)
            defer { sqlite3_close(migrated) }
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(migrated, "SELECT value FROM witness", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "copied WAL")
            for (suffix, data) in original {
                XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("history.sqlite" + suffix)), data)
            }
        }
    }
}
