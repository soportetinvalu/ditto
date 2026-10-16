// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Copy only, before ClipStore opens SQLite. The caller must stop the legacy app first.
enum LegacyMigration {
    static let legacyBundleID = "local.memorialocal.app"
    static let legacyDirectory = "MemoriaLocal"
    static let destinationDirectory = "NexClip"
    static let dateKey = "migrationFromLegacyAt"
    static let preferenceKeys = ["captureEnabled", "paused", "pollMilliseconds", "excluded", "allowed",
                                 "days", "maxCount", "megabytes", "separator", "reorder", "autoPaste",
                                 "hotKey", "hotModifiers", "appearance", "customTypes"]
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NexClip/migracion.log")

    static func message(at timestamp: String) -> String { "migrado desde Memoria Local el \(timestamp)" }
    static func diagnostic(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: dateKey).map { message(at: $0) } ?? "Sin migración de datos anterior registrada."
    }

    /// A receipt also recovers preferences if the process stops just after publishing the database.
    @discardableResult
    static func run(applicationSupport: URL, defaults: UserDefaults,
                    destinationDomain: String = "com.nexclip.app", legacyPreferences: [String: Any],
                    legacyIsRunning: Bool = false, at date: Date = Date(), log: URL = logURL) throws -> String? {
        let manager = FileManager.default
        let source = applicationSupport.appendingPathComponent(legacyDirectory, isDirectory: true)
        let target = applicationSupport.appendingPathComponent(destinationDirectory, isDirectory: true)
        let database = target.appendingPathComponent("history.sqlite")
        let receipt = target.appendingPathComponent("migration.plist")
        if manager.fileExists(atPath: database.path) {
            // Never import old history or preferences over an existing NexClip installation.
            if defaults.string(forKey: dateKey) == nil,
               let data = try? Data(contentsOf: receipt),
               let record = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
               let timestamp = record["date"] as? String, let values = record["preferences"] as? [String: Any] {
                return finish(values: values, timestamp: timestamp, defaults: defaults, domain: destinationDomain, log: log)
            }
            return nil
        }
        guard manager.fileExists(atPath: source.appendingPathComponent("history.sqlite").path) else { return nil }
        guard !legacyIsRunning else {
            throw LocalError("Sal de Memoria Local desde su menú Salir y vuelve a abrir NexClip para copiar el historial y los ajustes sin modificar el origen.")
        }
        let timestamp = ISO8601DateFormatter().string(from: date)
        let values = legacyPreferences.filter { preferenceKeys.contains($0.key) }
        let staging = applicationSupport.appendingPathComponent(".nexclip-migration-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        // Copy all sidecars, even SHM; never connect to, checkpoint, rename or remove the source.
        var names = [String]()
        for name in ["history.sqlite-wal", "history.sqlite-shm", "history.sqlite"] {
            let original = source.appendingPathComponent(name)
            if manager.fileExists(atPath: original.path) {
                let copy = staging.appendingPathComponent(name)
                try manager.copyItem(at: original, to: copy)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
                names.append(name)
            }
        }
        let record: [String: Any] = ["date": timestamp, "preferences": values]
        try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
            .write(to: staging.appendingPathComponent("migration.plist"), options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.appendingPathComponent("migration.plist").path)
        if !manager.fileExists(atPath: target.path) {
            // Normal first launch: an atomic directory rename publishes the complete snapshot and receipt.
            try manager.moveItem(at: staging, to: target)
            return finish(values: values, timestamp: timestamp, defaults: defaults, domain: destinationDomain, log: log)
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        // Refuse collisions. Publish the database last so partial copies are never opened.
        let publishing = ["migration.plist"] + names
        for name in publishing where manager.fileExists(atPath: target.appendingPathComponent(name).path) {
            throw LocalError("La migración no sobrescribirá el archivo existente \(name). El origen sigue intacto.")
        }
        var published = [URL]()
        do {
            for name in publishing {
                let destination = target.appendingPathComponent(name)
                try manager.moveItem(at: staging.appendingPathComponent(name), to: destination)
                published.append(destination)
            }
        } catch {
            for path in published.reversed() { try? manager.removeItem(at: path) }
            throw error
        }
        return finish(values: values, timestamp: timestamp, defaults: defaults, domain: destinationDomain, log: log)
    }

    private static func finish(values: [String: Any], timestamp: String, defaults: UserDefaults,
                               domain: String, log: URL) -> String {
        let existing = defaults.persistentDomain(forName: domain) ?? [:]
        for (key, value) in values where preferenceKeys.contains(key) && existing[key] == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(timestamp, forKey: dateKey)
        let text = message(at: timestamp)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try Data((text + "\n").utf8).write(to: log, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
        } catch { NSLog("NexClip: no se pudo guardar el log de migración: %@", error.localizedDescription) }
        NSLog("%@", text)
        return text
    }
}
