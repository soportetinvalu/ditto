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
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(refocus(_:)), name: Notification.Name("test.nexclip.refocus"), object: ready.path)
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
    @objc private func refocus(_ note: Notification) {
        // A fresh native window forces a real key-window change. Merely asking
        // the already-key external window to become key can be an AppKit no-op
        // while a nonactivating panel borrows its keyboard focus.
        let old = window
        let next = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 300, height: 120),
                            styleMask: [.titled], backing: .buffered, defer: false)
        next.isReleasedWhenClosed = false
        if let field { next.contentView?.addSubview(field) }
        window = next
        next.makeKeyAndOrderFront(nil)
        old?.close()
        focusAndMarkReady()
        if next.isKeyWindow {
            try? Data("refocused".utf8).write(to: ready.appendingPathExtension("refocused"), options: .atomic)
        }
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
