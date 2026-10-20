// SPDX-License-Identifier: GPL-3.0-only
// Opt-in test fixture, compiled separately; never shipped in NexClip.app.
// Empty fields only, no clipboard, AX, browser, network or keyboard injection.
import AppKit

final class FocusDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var field: NSTextField?
    let mode = CommandLine.arguments[1]
    let ready = URL(fileURLWithPath: CommandLine.arguments[2])

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field: NSTextField = mode == "secure" ? NSSecureTextField() : NSTextField()
        field.frame = NSRect(x: 20, y: 40, width: 260, height: 24)
        window.contentView?.addSubview(field)
        self.window = window; self.field = field
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        focusAndMarkReady()
    }
    func applicationDidBecomeActive(_ notification: Notification) { focusAndMarkReady() }
    private func focusAndMarkReady() {
        guard NSApp.isActive, let window, let field else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        if window.isKeyWindow && field.currentEditor() != nil {
            try? Data("ready-\(mode)".utf8).write(to: ready, options: .atomic)
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = FocusDelegate()
app.delegate = delegate
withExtendedLifetime(delegate) { app.run() }
