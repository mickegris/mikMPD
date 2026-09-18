// RemoteCommandTests.swift
// v1.7.1: lock-screen, Control Center and headphone commands.
import Testing
import Foundation
@testable import mikMPD

@Suite struct RemoteCommandMappingTests {
    /// v1.7 sent a bare `pause` for the headphone toggle, which MPD ignores on a
    /// stopped player.
    @Test func toggleOnAStoppedPlayerPlays() {
        #expect(remoteCommandMPD(.toggle, isPlaying: false, isPaused: false) == "play")
    }

    @Test func toggleUsesExplicitPauseForms() {
        #expect(remoteCommandMPD(.toggle, isPlaying: true, isPaused: false) == "pause 1")
        #expect(remoteCommandMPD(.toggle, isPlaying: false, isPaused: true) == "pause 0")
    }

    /// A lock-screen pause must never turn into a resume because state was stale.
    @Test func pauseIsIdempotent() {
        #expect(remoteCommandMPD(.pause, isPlaying: true, isPaused: false) == "pause 1")
        #expect(remoteCommandMPD(.pause, isPlaying: false, isPaused: true) == "pause 1")
        #expect(remoteCommandMPD(.pause, isPlaying: false, isPaused: false) == nil)
    }

    @Test func playResumesOrStarts() {
        #expect(remoteCommandMPD(.play, isPlaying: false, isPaused: true) == "pause 0")
        #expect(remoteCommandMPD(.play, isPlaying: false, isPaused: false) == "play")
        #expect(remoteCommandMPD(.play, isPlaying: true, isPaused: false) == nil)
    }

    @Test func skipsAlwaysSend() {
        #expect(remoteCommandMPD(.next, isPlaying: false, isPaused: false) == "next")
        #expect(remoteCommandMPD(.previous, isPlaying: true, isPaused: false) == "previous")
    }

    @Test func optimisticStateFollowsTheCommand() {
        #expect(remoteCommandResultIsPlaying(.play, isPlaying: false) == true)
        #expect(remoteCommandResultIsPlaying(.pause, isPlaying: true) == false)
        #expect(remoteCommandResultIsPlaying(.toggle, isPlaying: true) == false)
        #expect(remoteCommandResultIsPlaying(.toggle, isPlaying: false) == true)
        #expect(remoteCommandResultIsPlaying(.next, isPlaying: true) == nil)
    }
}

@Suite struct ConnectionRefreshTests {
    /// A phone suspended while paused wakes for a lock-screen press with a socket
    /// MPD dropped after its 60 s connection_timeout — reconnect before sending
    /// rather than wait out a 5 s read timeout.
    @Test func aLongQuietSocketIsRefreshed() {
        #expect(mpdConnectionNeedsRefresh(connected: true, idleSeconds: 120))
        #expect(!mpdConnectionNeedsRefresh(connected: true, idleSeconds: 2))
    }

    @Test func aDisconnectedSocketAlwaysIs() {
        #expect(mpdConnectionNeedsRefresh(connected: false, idleSeconds: 0))
    }
}
