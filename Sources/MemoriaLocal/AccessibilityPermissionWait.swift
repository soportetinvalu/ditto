// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// No UI or TCC side effects except the explicitly injected request.
/// The prompt result is asynchronous: only a subsequent trust check grants access.
final class AccessibilityPermissionWait {
    enum Phase: Equatable { case idle, waiting, granted, timedOut, cancelled }
    private(set) var phase: Phase = .idle
    private var deadline: TimeInterval = 0
    private let clock: () -> TimeInterval
    private let isTrusted: () -> Bool
    private let prompt: () -> Void

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         isTrusted: @escaping () -> Bool, prompt: @escaping () -> Void) {
        self.clock = clock; self.isTrusted = isTrusted; self.prompt = prompt
    }
    func request() {
        guard !isTrusted() else { phase = .granted; return }
        deadline = clock() + 60
        phase = .waiting
        prompt()
    }
    func check(onForeground: Bool = false) {
        guard phase == .waiting || (onForeground && phase == .timedOut) else { return }
        if isTrusted() { phase = .granted }
        else if clock() >= deadline { phase = .timedOut }
    }
    func cancel() { phase = .cancelled }
}
