// PlaybackClock.swift
// The playback values that change many times a second, kept out of MPDStore.
//
// `elapsed` used to be @Published on the store and advanced at 10 Hz. An
// ObservableObject has one objectWillChange for the whole object, so every one
// of the ~30 views holding `@EnvironmentObject var store` was invalidated ten
// times a second — including the Albums list, which regrouped ~820 albums in
// `body` each time. An iOS CPU resource report caught it: 57 % CPU for 2.5
// minutes, on battery. Only the views that show the time observe this object.
import SwiftUI
import Combine

@MainActor
final class PlaybackClock: ObservableObject {
    @Published var elapsed: Double = 0

    /// How many on-screen views display time right now. The 10 Hz display timer
    /// runs only while this is positive — nobody else needs sub-second elapsed.
    private(set) var observers = 0

    /// Set by the store; called whenever `observers` changes so it can start or
    /// stop the display timer.
    var onObserversChanged: (() -> Void)?

    func attach() { observers += 1; onObserversChanged?() }
    func detach() { observers = max(0, observers - 1); onObserversChanged?() }
}

/// Whether the 10 Hz display timer should run. Pure so it can be tested: the
/// point of each condition is energy — nothing ticks in the background, nothing
/// ticks for a screen that shows no time, and nothing ticks while paused.
nonisolated func displayTimerShouldRun(isPlaying: Bool, sceneActive: Bool, observers: Int) -> Bool {
    isPlaying && sceneActive && observers > 0
}

extension View {
    /// Marks a view as displaying the playback clock while it is on screen.
    func observesPlaybackClock(_ clock: PlaybackClock) -> some View {
        onAppear { clock.attach() }.onDisappear { clock.detach() }
    }
}
