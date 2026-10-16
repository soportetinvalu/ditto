// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security
import ClipCore

/// Optional, explicit diagnostic: unsupported database schema, not an authorization API.
/// Open existing databases READONLY; inspect only this client's Accessibility rows.
/// Never requests Full Disk Access, changes TCC, or bypasses a denied read.
enum AccessibilityTCCInspection {
    static let query = """
        SELECT client, client_type, auth_value, csreq FROM access
        WHERE service = 'kTCCServiceAccessibility'
          AND ((client_type = 0 AND client = ?1)
            OR (client_type = 1 AND client IN (?2, ?3))) LIMIT 16
        """
    static let unavailableExplanation = "TCC no legible: no se puede distinguir entrada ausente, denegada o identidad obsoleta. No se solicitan más permisos."

    static func report(bundle: Bundle = .main) -> [String] {
        let user = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        let system = "/Library/Application Support/com.apple.TCC/TCC.db"
        guard let identifier = bundle.bundleIdentifier else { return ["TCC: bundle id no disponible"] }
        return ["TCC: lectura opcional de esquema interno, solo filas propias; no es API pública."] + [system, user].flatMap {
            inspect(path: $0, identifier: identifier, bundlePath: bundle.bundleURL.path,
                    executablePath: bundle.executableURL?.path ?? "")
        }
    }
    static func inspect(path: String, identifier: String, bundlePath: String, executablePath: String) -> [String] {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { if let db { sqlite3_close(db) } }
        let header = "TCC [\(path)]"
        guard rc == SQLITE_OK, let db else {
            let systemError = db.map { sqlite3_system_errno($0) } ?? 0
            return ["\(header): open rc=\(rc); errno=\(systemError). \(unavailableExplanation)"]
        }
        sqlite3_busy_timeout(db, 100)
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, query, -1, &statement, nil)
        defer { if let statement { sqlite3_finalize(statement) } }
        guard prepared == SQLITE_OK, let statement else {
            return ["\(header): prepare rc=\(prepared); esquema o acceso no disponible. \(unavailableExplanation)"]
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in [identifier, bundlePath, executablePath].enumerated() {
            let bound = value.withCString { sqlite3_bind_text(statement, Int32(offset + 1), $0, -1, transient) }
            guard bound == SQLITE_OK else { return ["\(header): bind rc=\(bound). \(unavailableExplanation)"] }
        }
        var rows = [String]()
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                return ["\(header): step rc=\(step). \(unavailableExplanation)"]
            }
            let client = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "NULL"
            let type = sqlite3_column_int(statement, 1); let auth = sqlite3_column_int(statement, 2)
            var line = "client=\(client); client_type=\(type); auth_value=\(auth) (valor bruto, no autorización efectiva)"
            if let pointer = sqlite3_column_blob(statement, 3), sqlite3_column_bytes(statement, 3) > 0 {
                let data = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 3)))
                line += "; " + requirementReport(data)
            } else { line += "; csreq=NULL; identidad no evaluable" }
            rows.append(line)
        }
        return ["\(header): lectura correcta; \(rows.count) filas propias (máximo 16; solo esta base, no estado global)."] + rows
    }
    static func requirementReport(_ data: Data) -> String {
        var requirement: SecRequirement?
        let decode = SecRequirementCreateWithData(data as CFData, SecCSFlags(rawValue: 0), &requirement)
        guard decode == errSecSuccess, let requirement else { return "csreq no decodificable; OSStatus=\(decode)" }
        var text: CFString?
        let textRC = SecRequirementCopyString(requirement, SecCSFlags(rawValue: 0), &text)
        var code: SecCode?
        let selfRC = SecCodeCopySelf(SecCSFlags(rawValue: 0), &code)
        let evaluation = code.map { SecCodeCheckValidity($0, SecCSFlags(rawValue: 0), requirement) }
        return "csreq=\(text as String? ?? "no disponible (\(textRC))"); SecCodeCopySelf=\(selfRC); " +
            "csreq frente a este proceso: \(evaluation.map { String($0) } ?? "no evaluado") (0=coincide; otros códigos no implican por sí solos cdhash antiguo)"
    }
}
