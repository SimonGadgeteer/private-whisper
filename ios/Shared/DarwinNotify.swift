// Portions adapted from Dictus (https://github.com/getdictus/dictus-ios),
// DictusCore/DarwinNotifications.swift (registry technique). MIT License, Copyright (c) 2026 PIVI Solutions. See THIRD_PARTY_NOTICES.md.
import Foundation

enum DarwinName {
    static let start = "ch.simonschwarz.pw.start",   stop = "ch.simonschwarz.pw.stop"
    static let cancel = "ch.simonschwarz.pw.cancel", status = "ch.simonschwarz.pw.status"
    static let transcript = "ch.simonschwarz.pw.transcript", level = "ch.simonschwarz.pw.level"
    static let released = "ch.simonschwarz.pw.released",    result = "ch.simonschwarz.pw.result"
}

// CFNotificationCallback is a C function pointer: it cannot capture context, so look callbacks up by name.
private let registryLock = NSLock()
nonisolated(unsafe) private var registry: [String: () -> Void] = [:]
private let trampoline: CFNotificationCallback = { _, _, name, _, _ in
    guard let name else { return }
    let key = name.rawValue as String
    let callback = registryLock.withLock { registry[key] }
    callback?()                                  // arbitrary thread: callers hop with onMain
}

enum DarwinNotify {
    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }
    /// Call once per name per process (a second call replaces the callback).
    static func observe(_ name: String, _ callback: @escaping () -> Void) {
        let isNew: Bool = registryLock.withLock {
            let fresh = registry[name] == nil
            registry[name] = callback
            return fresh
        }
        guard isNew else { return }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, trampoline,
                                        name as CFString, nil, .deliverImmediately)
    }
}

func onMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}
