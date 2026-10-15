// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import ClipCore

struct Representation: Codable, Equatable {
    var item: Int
    var type: String
    var data: Data
}
struct Clip: Identifiable {
    let id: String
    var title: String
    var text: String
    var source: String
    var created: Double
    var lastSeen: Double
    var lastUsed: Double?
    var copies: Int
    var favorite: Bool
    var protected: Bool
    var sticky: Int
    var group: String?
    var alias: String?
    var deleted: Bool
    var bytes: Int
}
struct ClipGroup: Codable { var id: String; var name: String; var parent: String? }
struct ArchivedClip: Codable {
    var id: String; var title: String; var text: String; var source: String
    var created: Double; var favorite: Bool; var protected: Bool; var sticky: Int
    var group: String?; var alias: String?; var representations: [Representation]
}
struct ClipArchive: Codable {
    var version = 1
    var groups: [ClipGroup]
    var clips: [ArchivedClip]
}
struct LocalError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// SQLite is only used on the main thread in the application; tests can own an isolated store.
final class ClipStore {
    private(set) var db: OpaquePointer!
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let path: String
    init(path: String) throws {
        self.path = path
        let result = path.withCString { cm_open($0, &db) }
        let validated = result == SQLITE_OK && path != ":memory:" ? cm_validate_file(path) : result
        guard validated == SQLITE_OK else {
            let error = LocalError("No se pudo abrir el historial (SQLite \(validated)). No se reemplazó la base.")
            if db != nil { sqlite3_close(db); db = nil }
            throw error
        }
    }
    deinit { if db != nil { sqlite3_close(db) } }

    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) throws -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in args.enumerated() {
            let n = Int32(i + 1)
            let status: Int32
            switch value {
            case nil: status = sqlite3_bind_null(stmt, n)
            case let v as String: status = v.withCString { sqlite3_bind_text(stmt, n, $0, -1, transient) }
            case let v as Int: status = sqlite3_bind_int64(stmt, n, Int64(v))
            case let v as Double: status = sqlite3_bind_double(stmt, n, v)
            case let v as Data: status = v.withUnsafeBytes { sqlite3_bind_blob(stmt, n, $0.baseAddress, Int32(v.count), transient) }
            default: throw LocalError("Tipo SQL no admitido")
            }
            guard status == SQLITE_OK else { throw failure() }
        }
        var rows = [[String: Any]]()
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return rows }
            guard rc == SQLITE_ROW else { throw failure() }
            var row = [String: Any]()
            for i in 0..<sqlite3_column_count(stmt) {
                let key = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[key] = Int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row[key] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT: row[key] = String(cString: sqlite3_column_text(stmt, i))
                case SQLITE_BLOB:
                    let size = Int(sqlite3_column_bytes(stmt, i))
                    row[key] = size == 0 ? Data() : Data(bytes: sqlite3_column_blob(stmt, i)!, count: size)
                default: break
                }
            }
            rows.append(row)
        }
    }
    private func failure() -> LocalError {
        // Do not log content, SQL bindings or clipboard payloads.
        LocalError("La operación del historial falló (SQLite \(sqlite3_errcode(db))).")
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE")
        do { let result = try body(); try run("COMMIT"); return result }
        catch { try? run("ROLLBACK"); throw error }
    }
    static func fingerprint(_ reps: [Representation]) -> String {
        var digest = SHA256()
        for rep in reps.sorted(by: { ($0.item, $0.type) < ($1.item, $1.type) }) {
            // Length prefixes avoid boundary collisions and include native item order.
            for data in [Data(String(rep.item).utf8), Data(rep.type.utf8), rep.data] {
                var length = UInt64(data.count).bigEndian
                withUnsafeBytes(of: &length) { digest.update(data: Data($0)) }
                digest.update(data: data)
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func validate(_ reps: [Representation]) throws {
        guard !reps.isEmpty, reps.count <= Int(CM_MAX_REPRESENTATIONS),
              reps.reduce(0, { $0 + $1.data.count }) <= Int(CM_MAX_BYTES),
              reps.allSatisfy({ (0...255).contains($0.item) && !$0.type.isEmpty && $0.type.utf8.count <= 512 && !$0.type.contains("\0") }),
              Set(reps.map { "\($0.item):\($0.type)" }).count == reps.count else {
            throw LocalError("La copia excede 32 MiB/256 formatos o contiene datos inválidos.")
        }
    }
    @discardableResult
    func capture(_ reps: [Representation], title: String, text: String, source: String,
                 now: Double = Date().timeIntervalSince1970) throws -> (id: String, duplicate: Bool) {
        try Self.validate(reps)
        let blobs = reps.map { $0.data as NSData }
        let types = reps.map { $0.type as NSString }
        var native = reps.enumerated().map { i, rep in
            CMRepresentation(item_index: Int32(rep.item), type: types[i].utf8String,
                             bytes: blobs[i].bytes, length: blobs[i].length)
        }
        var output = [CChar](repeating: 0, count: 37)
        let id = UUID().uuidString
        let hash = Self.fingerprint(reps)
        let rc = withExtendedLifetime((blobs, types)) {
            native.withUnsafeMutableBufferPointer { buffer in
                cm_capture(db, id, hash, title, text, source, now, buffer.baseAddress, buffer.count, &output)
            }
        }
        guard rc >= 0 else { throw LocalError("No se pudo guardar la copia (SQLite \(-rc)).") }
        return (String(cString: output), rc == 1)
    }
    private func clip(_ row: [String: Any]) -> Clip {
        func number(_ key: String) -> Double { (row[key] as? Double) ?? Double(row[key] as? Int ?? 0) }
        return Clip(id: row["id"] as! String, title: row["title"] as! String,
                    text: row["plain_text"] as! String, source: row["source"] as! String,
                    created: number("created"), lastSeen: number("last_seen"),
                    lastUsed: row["last_used"] == nil ? nil : number("last_used"),
                    copies: row["copies"] as? Int ?? 1, favorite: (row["favorite"] as? Int) == 1,
                    protected: (row["protected"] as? Int) == 1, sticky: row["sticky"] as? Int ?? 0,
                    group: row["group_id"] as? String, alias: row["alias"] as? String,
                    deleted: row["deleted_at"] != nil, bytes: row["total_bytes"] as? Int ?? 0)
    }
    func clips(search: String = "", regex: Bool = false, favorites: Bool = false,
               group: String? = nil, trash: Bool = false) throws -> [Clip] {
        var sql = "SELECT * FROM clips WHERE deleted_at IS \(trash ? "NOT NULL" : "NULL")"
        var args = [Any?]()
        if favorites { sql += " AND favorite=1" }
        if let group {
            sql += " AND group_id IN (WITH RECURSIVE tree(id) AS (SELECT ? UNION SELECT groups.id FROM groups JOIN tree ON groups.parent_id=tree.id) SELECT id FROM tree)"
            args.append(group)
        }
        // Substring search uses instr instead of LIKE: %, _ and quotes are literal.
        if !search.isEmpty && !regex {
            sql += " AND (instr(lower(title),lower(?))>0 OR instr(lower(plain_text),lower(?))>0 OR instr(lower(coalesce(alias,'')),lower(?))>0)"
            args += [search, search, search]
        }
        sql += " ORDER BY sticky DESC,max(coalesce(last_used,0),last_seen) DESC,id"
        var result = try run(sql, args).map(clip)
        if regex && !search.isEmpty {
            // A deliberately restricted dialect avoids catastrophic nested quantifiers.
            // No groups, alternation, braces, backreferences, lookaround or multiple repeats.
            let forbidden = CharacterSet(charactersIn: "(){}|\\\\")
            guard search.count <= 128, search.rangeOfCharacter(from: forbidden) == nil,
                  search.filter({ "*+?".contains($0) }).count <= 1 else {
                throw LocalError("Regex admite patrones simples de hasta 128 caracteres, sin grupos, alternativas, llaves, escapes ni repetición múltiple.")
            }
            let expression = try NSRegularExpression(pattern: search, options: [.caseInsensitive])
            // Explicit bounded preview scope, not unbounded content regex on the UI thread.
            result = result.filter { value in
                [value.title, String(value.text.prefix(8192)), value.alias ?? ""].contains { s in
                    expression.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
                }
            }
        }
        return result
    }
    func representations(_ id: String) throws -> [Representation] {
        try run("SELECT * FROM representations WHERE clip_id=? ORDER BY item_index,type", [id]).map {
            Representation(item: $0["item_index"] as! Int, type: $0["type"] as! String, data: $0["payload"] as! Data)
        }
    }
    func metadata(_ clip: Clip) throws {
        try run("UPDATE clips SET title=?,favorite=?,protected=?,sticky=?,group_id=?,alias=? WHERE id=?",
                [clip.title, clip.favorite ? 1 : 0, clip.protected ? 1 : 0, clip.sticky, clip.group,
                 clip.alias?.isEmpty == false ? clip.alias : nil, clip.id])
    }
    func markUsed(_ ids: [String], reorder: Bool) throws {
        if reorder { for id in ids { try run("UPDATE clips SET last_used=? WHERE id=?", [Date().timeIntervalSince1970, id]) } }
    }
    func trash(_ ids: [String]) throws {
        try transaction { for id in ids { try run("UPDATE clips SET deleted_at=? WHERE id=?", [Date().timeIntervalSince1970, id]) } }
    }
    func restore(_ ids: [String]) throws {
        // Collision rejects the entire transaction, retaining trash instead of overwriting an active clip.
        try transaction { for id in ids { try run("UPDATE clips SET deleted_at=NULL WHERE id=?", [id]) } }
    }
    func deletePermanently(_ ids: [String]) throws {
        try transaction { for id in ids { try run("DELETE FROM clips WHERE id=? AND deleted_at IS NOT NULL", [id]) } }
    }
    func groups() throws -> [ClipGroup] {
        try run("SELECT * FROM groups ORDER BY name COLLATE NOCASE").map {
            ClipGroup(id: $0["id"] as! String, name: $0["name"] as! String, parent: $0["parent_id"] as? String)
        }
    }
    func addGroup(name: String, parent: String?) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalError("El grupo necesita un nombre.") }
        try run("INSERT INTO groups VALUES(?,?,?)", [UUID().uuidString, name, parent])
    }
    func renameGroup(id: String, name: String) throws {
        guard !name.isEmpty else { throw LocalError("El grupo necesita un nombre.") }
        try run("UPDATE groups SET name=? WHERE id=?", [name, id])
    }
    func removeGroup(id: String) throws {
        // Children prevent deletion via FK; clips are moved to the root, never deleted.
        try run("DELETE FROM groups WHERE id=?", [id])
    }
    func buffer(_ slot: Int, clip: String? = nil) throws -> String? {
        if let clip { try run("INSERT INTO buffers VALUES(?,?) ON CONFLICT(slot) DO UPDATE SET clip_id=excluded.clip_id", [slot, clip]) }
        return try run("SELECT buffers.clip_id FROM buffers JOIN clips ON clips.id=buffers.clip_id WHERE slot=? AND deleted_at IS NULL", [slot]).first?["clip_id"] as? String
    }
    func retain(days: Int, count: Int, megabytes: Int) throws {
        let now = Date().timeIntervalSince1970
        let rc = cm_retire(db, days == 0 ? 0 : now - Double(days) * 86400,
                           Int32(max(1, count)), Int64(max(1, megabytes)) * 1024 * 1024, now)
        guard rc == SQLITE_OK else { throw failure() }
    }
    func archive(ids: [String]? = nil) throws -> ClipArchive {
        let selected = try clips().filter { ids == nil || ids!.contains($0.id) }
        return try ClipArchive(groups: groups(), clips: selected.map { c in
            ArchivedClip(id: c.id, title: c.title, text: c.text, source: c.source, created: c.created,
                         favorite: c.favorite, protected: c.protected, sticky: c.sticky,
                         group: c.group, alias: c.alias, representations: try representations(c.id))
        })
    }
    func importArchive(_ archive: ClipArchive) throws -> Int {
        guard archive.version == 1, archive.clips.count <= 10000, archive.groups.count <= 1000 else {
            throw LocalError("Archivo incompatible o demasiado grande.")
        }
        for clip in archive.clips {
            try Self.validate(clip.representations)
            guard clip.title.utf8.count <= 4096, clip.text.utf8.count <= Int(CM_MAX_BYTES),
                  clip.source.utf8.count <= 512, (clip.alias?.utf8.count ?? 0) <= 256,
                  clip.created.isFinite else { throw LocalError("Metadatos de importación inválidos o demasiado grandes.") }
        }
        guard archive.groups.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 1024 }) else { throw LocalError("Nombre de grupo inválido.") }
        let groupIDs = Set(archive.groups.map(\.id))
        guard groupIDs.count == archive.groups.count, Set(archive.clips.map(\.id)).count == archive.clips.count else { throw LocalError("Identificadores duplicados en el archivo.") }
        for group in archive.groups {
            var seen = Set([group.id]); var parent = group.parent
            while let id = parent {
                guard groupIDs.contains(id), !seen.contains(id) else { throw LocalError("Jerarquía de grupos inválida.") }
                seen.insert(id); parent = archive.groups.first { $0.id == id }?.parent
            }
        }
        guard archive.clips.allSatisfy({ $0.group == nil || groupIDs.contains($0.group!) }) else { throw LocalError("Grupo de copia inexistente.") }
        return try transaction {
            var mapping = [String: String]()
            var remaining = archive.groups
            while !remaining.isEmpty {
                let ready = remaining.filter { g in g.parent == nil || !remaining.contains(where: { $0.id == g.parent }) }
                guard !ready.isEmpty else { throw LocalError("Ciclo de grupos.") }
                for g in ready {
                    let parent = g.parent.flatMap { mapping[$0] }
                    if let existing = try run("SELECT id FROM groups WHERE name=? AND parent_id IS ?", [g.name, parent]).first?["id"] as? String {
                        mapping[g.id] = existing
                    } else {
                        let id = UUID().uuidString
                        mapping[g.id] = id
                        try run("INSERT INTO groups VALUES(?,?,?)", [id, g.name, parent])
                    }
                }
                let done = Set(ready.map(\.id)); remaining.removeAll { done.contains($0.id) }
            }
            var added = 0
            for c in archive.clips {
                let result = try capture(c.representations, title: c.title, text: c.text, source: c.source, now: c.created)
                if !result.duplicate {
                    added += 1
                    try run("UPDATE clips SET favorite=?,protected=?,sticky=?,group_id=?,alias=? WHERE id=?",
                            [c.favorite ? 1 : 0, c.protected ? 1 : 0, max(-1, min(1, c.sticky)), c.group.flatMap { mapping[$0] }, nil, result.id])
                    // Aliases are user-unique. Import doesn't overwrite a pre-existing alias.
                    if let alias = c.alias, !alias.isEmpty,
                       try run("SELECT id FROM clips WHERE alias=? AND deleted_at IS NULL", [alias]).isEmpty {
                        try run("UPDATE clips SET alias=? WHERE id=?", [alias, result.id])
                    }
                }
            }
            return added
        }
    }
    func backup(to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw LocalError("El respaldo debe tener un nombre nuevo: no se sobrescribe.") }
        guard cm_backup(db, url.path) == SQLITE_OK, cm_validate_file(url.path) == SQLITE_OK else { throw LocalError("Falló la validación del respaldo.") }
    }
    func mergeBackup(_ url: URL) throws -> Int {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 128 * 1024 * 1024 else { throw LocalError("La fusión de respaldo supera el límite de 128 MiB de esta versión.") }
        // Read bytes only from the supplied file. Never open/migrate/chmod it with SQLite,
        // and never copy a symlink that could make the temporary path point back to it.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("restore.sqlite")
        let data = try Data(contentsOf: url)
        guard data.count <= 128 * 1024 * 1024 else { throw LocalError("El respaldo cambió o supera 128 MiB.") }
        try data.write(to: copy, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
        guard cm_validate_file(copy.path) == SQLITE_OK else { throw LocalError("Respaldo incompatible o dañado.") }
        let archive: ClipArchive = try {
            let other = try ClipStore(path: copy.path)
            return try other.archive()
        }()
        return try importArchive(archive)
    }
    func compact() throws { try run("PRAGMA wal_checkpoint(TRUNCATE)"); try run("VACUUM") }
}
