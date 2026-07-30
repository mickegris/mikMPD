// MPDCommandLog.swift
// A small ring buffer of recent MPD commands with timings.
//
// Motivation: the daemon has hung hard enough to need `kill -9`, and nothing on
// the client side recorded what it was doing at the time. Every command now lands
// here with its duration and outcome, so the next occurrence names its own culprit
// (More → Diagnostics). See plans/mpd-hang-investigation.md.
import Foundation

nonisolated struct MPDCommandLogEntry: Identifiable {
    let id = UUID()
    let at: Date
    let command: String
    let duration: TimeInterval
    let outcome: String

    /// Anything this slow is worth looking at first when diagnosing a stall.
    var isSlow: Bool { duration >= 2 }
}

/// Thread-safe: written from the store's serial queue Q, read from the main actor.
nonisolated final class MPDCommandLog: @unchecked Sendable {
    static let shared = MPDCommandLog()

    private let lock = NSLock()
    private var entries: [MPDCommandLogEntry] = []
    private let capacity = 250

    func record(command: String, duration: TimeInterval, outcome: String) {
        // Commands carry quoted user data (album names, URIs); keep them short so a
        // long `find` filter can't dominate the buffer.
        let trimmed = command.count > 120 ? String(command.prefix(120)) + "…" : command
        let entry = MPDCommandLogEntry(at: Date(), command: trimmed,
                                       duration: duration, outcome: outcome)
        lock.lock()
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        lock.unlock()
    }

    /// Newest first.
    var recent: [MPDCommandLogEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries.reversed()
    }

    func clear() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }

    /// Plain-text dump for the copy-to-clipboard action.
    func plainText() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return recent.map {
            String(format: "%@  %6.0f ms  %@  — %@",
                   f.string(from: $0.at), $0.duration * 1000, $0.command, $0.outcome)
        }.joined(separator: "\n")
    }
}
