// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import ApplicationServices
import Darwin
import Security

/// Local, explicit diagnosis only. Never reads clipboard contents or the history store.
enum AccessibilityDiagnostics {
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MemoriaLocal/diagnostico-accesibilidad.txt")

    private static func status(_ value: OSStatus) -> String {
        let message = SecCopyErrorMessageString(value, nil) as String? ?? "sin descripción"
        return "\(value) (\(message))"
    }
    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private static func translated() -> String {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rc = sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0)
        if rc == 0 { return value == 1 ? "true" : "false" }
        let error = errno
        return error == ENOENT ? "false (sysctl no disponible en proceso nativo)" : "desconocido (errno=\(error))"
    }
    private static func quarantine(_ path: String) -> String {
        let size = path.withCString { pathPointer in
            "com.apple.quarantine".withCString { name in getxattr(pathPointer, name, nil, 0, 0, 0) }
        }
        if size >= 0 { return "true (\(size) bytes; no se modifica)" }
        let error = errno
        return error == ENOATTR ? "false" : "desconocido (errno=\(error))"
    }
    // This process only: recording never requests permission; the explicit button does.
    private(set) static var promptInvocationCount = 0
    private(set) static var lastPromptAt: Date?
    static var lastPromptReturn: Bool?
    static var lastReset = "no ejecutado"
    static var tccBeforeReset: String?
    static func recordPrompt(at date: Date = Date()) {
        promptInvocationCount += 1; lastPromptAt = date
    }
    static func promptSummary(count: Int, lastAt: Date?) -> String {
        let when = lastAt.map { ISO8601DateFormatter().string(from: $0) } ?? "nunca"
        return "kAXTrustedCheckOptionPrompt: prompt=true invocado en este proceso: \(count > 0); llamadas: \(count); última invocación (UTC): \(when)"
    }
    static func report(bundle: Bundle = .main, includeTCC: Bool = false) -> String {
        let info = bundle.infoDictionary ?? [:]
        let id = bundle.bundleIdentifier ?? "sin identificador"
        var lines = ["Memoria Local — diagnóstico de Accesibilidad", "No contiene el historial ni el contenido anterior del portapapeles.",
                     "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "versión: \(info["CFBundleShortVersionString"] ?? "desconocida") (\(info["CFBundleVersion"] ?? "desconocida"))",
                     "commit: \(info["MemoriaLocalCommit"] ?? "no incorporado en este build")",
                     "bundle: \(bundle.bundleURL.path)", "ejecutable: \(bundle.executableURL?.path ?? "desconocido")",
                     "pid: \(ProcessInfo.processInfo.processIdentifier)", "bundle id: \(id)",
                     "AXIsProcessTrusted(): \(AXIsProcessTrusted())",
                     promptSummary(count: promptInvocationCount, lastAt: lastPromptAt),
                     "Último retorno inmediato de prompt=true: \(lastPromptReturn.map { String($0) } ?? "no invocado"); no indica que el aviso se haya mostrado ni la razón de una denegación.",
                     "AXIsProcessTrustedWithOptions(prompt:false): \(AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary))",
                     "Restablecimiento: \(lastReset)",
                     "quarantine (bundle): \(quarantine(bundle.bundleURL.path))",
                     "instancias con el mismo bundle id: \(NSRunningApplication.runningApplications(withBundleIdentifier: id).count)",
                     "Rosetta: \(translated())"]
        var code: SecCode?
        // kSecCSDefaultFlags is 0; the C constant is unavailable to Swift in this SDK.
        let selfRC = SecCodeCopySelf(SecCSFlags(rawValue: 0), &code)
        lines.append("SecCodeCopySelf: \(status(selfRC))")
        if selfRC == errSecSuccess, let code {
            lines.append("SecCodeCheckValidity(default): \(status(SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), nil)))")
            lines.append("SecCodeCheckValidity(strict): \(status(SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)))")
            var disk: SecStaticCode?
            let diskRC = SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &disk)
            lines.append("SecCodeCopyStaticCode: \(status(diskRC))")
            if diskRC == errSecSuccess, let disk {
                // Static validation also checks on-disk resources; dynamic validity alone is not enough.
                lines.append("SecStaticCodeCheckValidity(default): \(status(SecStaticCodeCheckValidity(disk, SecCSFlags(rawValue: 0), nil)))")
                lines.append("SecStaticCodeCheckValidity(strict): \(status(SecStaticCodeCheckValidity(disk, SecCSFlags(rawValue: kSecCSStrictValidate), nil)))")
                var designated: SecRequirement?
                let requirementRC = SecCodeCopyDesignatedRequirement(disk, SecCSFlags(rawValue: 0), &designated)
                if requirementRC == errSecSuccess, let designated {
                    var requirementText: CFString?
                    let rc = SecRequirementCopyString(designated, SecCSFlags(rawValue: 0), &requirementText)
                    lines.append("DR del binario actual: \(requirementText as String? ?? "no disponible (\(rc))"); no es el csreq guardado por TCC")
                } else { lines.append("DR del binario actual: no disponible (\(requirementRC))") }
                var signing: CFDictionary?
                let signingRC = SecCodeCopySigningInformation(disk, SecCSFlags(rawValue: kSecCSSigningInformation), &signing)
                lines.append("SecCodeCopySigningInformation: \(status(signingRC)) (información, no prueba de validez)")
                let values = signing as? [String: Any] ?? [:]
                lines.append("identifier: \(values[kSecCodeInfoIdentifier as String] ?? "ausente")")
                lines.append("cdhash: \((values[kSecCodeInfoUnique as String] as? Data).map(hex) ?? "ausente")")
                if let flags = values[kSecCodeInfoFlags as String] as? NSNumber {
                    lines.append("flags: \(String(format: "0x%x", flags.uint32Value))")
                } else { lines.append("flags: ausentes") }
                lines.append("teamid: \(values[kSecCodeInfoTeamIdentifier as String] ?? "ausente")")
                if let entitlements = values[kSecCodeInfoEntitlementsDict as String],
                   let xml = try? PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0),
                   let text = String(data: xml, encoding: .utf8) {
                    lines.append("entitlements:\n\(text)")
                } else { lines.append("entitlements: ausentes") }
            } else { lines.append("SigningInformation y validación estática: no ejecutadas (falló CopyStaticCode)") }
        } else { lines.append("Validación y SigningInformation: no ejecutadas (falló CopySelf)") }
        lines.append("Las APIs AX solo devuelven confianza efectiva; no distinguen sin entrada/denegación/csreq incompatible.")
        if includeTCC { lines += AccessibilityTCCInspection.report(bundle: bundle) }
        if let tccBeforeReset { lines += ["TCC observado antes del último restablecimiento:", tccBeforeReset] }
        lines.append("Firma ad hoc: el identificador no garantiza identidad TCC estable entre builds. Este informe no concede ni restablece permisos.")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Uses the same own-write exclusion as normal copies, including while capture is paused.
    @discardableResult
    static func copy(_ text: String, monitor: ClipboardMonitor, destination: URL = logURL) throws -> URL {
        let manager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try Data(text.utf8).write(to: destination, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        try monitor.write([Representation(item: 0, type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))])
        return destination
    }
}
