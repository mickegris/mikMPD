// ArtFetch.swift
// Concurrency control for album-art fetching.
//
// The album grid puts hundreds of tiles on screen (802 albums on a typical
// library). Before this, every tile spawned an unstructured Task that went
// straight to MusicBrainz + CoverArtArchive — up to ~15 network round trips per
// album, unbounded in parallel, against a service that rate-limits to roughly one
// request per second. That is why the grid took minutes to fill.
import Foundation

/// Caps how many art fetches run at once. Slots are handed directly from a
/// finishing fetch to the next waiter, so `active` never exceeds `limit`.
actor ArtFetchGate {
    static let shared = ArtFetchGate(limit: 4)

    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
        // Resumed by release(), which handed its slot over without decrementing.
    }

    func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Serialises MusicBrainz requests to one per second. Their usage policy requires
/// this; ignoring it earns 503s, which is both slower and rude.
actor MusicBrainzThrottle {
    static let shared = MusicBrainzThrottle()

    private var nextAllowed: Date = .distantPast
    private let interval: TimeInterval = 1.1

    func wait() async {
        let now = Date()
        let slot = max(now, nextAllowed)
        nextAllowed = slot.addingTimeInterval(interval)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }
    }
}
