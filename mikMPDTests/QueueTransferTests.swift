// QueueTransferTests.swift
// The transfer itself is I/O, but the decisions inside it are not — and the
// ordering bug it guards against is invisible without two partitions and a
// stopwatch, which is exactly why these are pure functions.
import Testing
import Foundation
@testable import mikMPD

@Suite struct TransferResumeCommandTests {
    /// `seekcur` ACKs on a stopped player — after `load` the partition *is*
    /// stopped — so `play` must come first. Reversed, the track silently starts
    /// from zero and the transfer looks like it worked.
    @Test func playingResumesAtTheSamePosition() {
        let cmds = transferResumeCommands(state: .playing, pos: 4, elapsed: 61.5)
        #expect(cmds.first == "play 4")
        #expect(cmds.contains { $0.hasPrefix("seekcur 61.5") })
        #expect(!cmds.contains("pause 1"))
    }

    /// The pause has to come *after* the seek. Pausing first leaves MPD paused
    /// at zero and the seek then has nothing to act on.
    @Test func pausedEndsPausedAtTheSamePosition() {
        let cmds = transferResumeCommands(state: .paused, pos: 2, elapsed: 30)
        #expect(cmds.first == "play 2")
        #expect(cmds.last == "pause 1")
        let seekIdx = cmds.firstIndex { $0.hasPrefix("seekcur") }
        let pauseIdx = cmds.firstIndex(of: "pause 1")
        #expect(seekIdx != nil && pauseIdx != nil && seekIdx! < pauseIdx!)
    }

    @Test func stoppedTransfersTheQueueButStartsNothing() {
        #expect(transferResumeCommands(state: .stopped, pos: 3, elapsed: 12).isEmpty)
    }

    @Test func noSeekAtTheStartOfATrack() {
        // Seeking to ~0 is a wasted round trip and can nudge the position.
        #expect(transferResumeCommands(state: .playing, pos: 0, elapsed: 0)
                == ["play 0"])
        #expect(transferResumeCommands(state: .playing, pos: 0, elapsed: 0.2)
                == ["play 0"])
    }

    @Test func negativePositionIsRefused() {
        // playlistPos is -1 when nothing is current.
        #expect(transferResumeCommands(state: .playing, pos: -1, elapsed: 10).isEmpty)
    }
}

@Suite struct TransferTempPlaylistTests {
    @Test func namesAreUniquePerTransfer() {
        // One fixed name would collide between two devices transferring at the
        // same moment, and the second save would overwrite a queue in flight.
        let names = Set((0..<200).map { _ in transferTempPlaylistName() })
        #expect(names.count == 200)
    }

    @Test func namesAreLegalMPDPlaylistNames() {
        for _ in 0..<50 {
            let n = transferTempPlaylistName()
            #expect(n.hasPrefix(transferPlaylistPrefix))
            #expect(validatePlaylistName(n) != nil)   // no slashes, no newlines
        }
    }
}

@Suite struct StaleTransferPlaylistTests {
    private func iso(_ offsetSeconds: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date().addingTimeInterval(offsetSeconds))
    }

    @Test func oldOrphanIsSwept() {
        #expect(isStaleTransferPlaylist(name: ".mikmpd-transfer-deadbeef",
                                        lastModified: iso(-3600)))
    }

    /// The gate is the whole point: an ungated sweep deletes another device's
    /// transfer while it is in flight — becoming the bug it is meant to fix.
    @Test func freshOrphanIsLeftAlone() {
        #expect(!isStaleTransferPlaylist(name: ".mikmpd-transfer-deadbeef",
                                         lastModified: iso(-5)))
    }

    @Test func ordinaryPlaylistsAreNeverSwept() {
        #expect(!isStaleTransferPlaylist(name: "Road Trip", lastModified: iso(-99999)))
        #expect(!isStaleTransferPlaylist(name: ".mikmpd", lastModified: iso(-99999)))
    }

    /// Never delete something we cannot date.
    @Test func undatableEntriesAreNeverSwept() {
        #expect(!isStaleTransferPlaylist(name: ".mikmpd-transfer-deadbeef", lastModified: ""))
        #expect(!isStaleTransferPlaylist(name: ".mikmpd-transfer-deadbeef", lastModified: "yesterday"))
    }

    @Test func parsesMPDsTimestampFormat() {
        #expect(iso8601Date("2026-09-10T08:14:22Z") != nil)
        #expect(iso8601Date("not a date") == nil)
    }
}

@Suite struct TransferRefusalTests {
    private func reason(queueEmpty: Bool = false, cd: Bool = false,
                        target: String = "Kitchen", current: String = "Living Room",
                        stored: Bool = true) -> String? {
        transferRefusalReason(queueIsEmpty: queueEmpty, containsCDTracks: cd,
                              targetPartition: target, currentPartition: current,
                              storedPlaylistsAvailable: stored)
    }

    @Test func aTransferableQueueIsAllowed() {
        #expect(reason() == nil)
    }

    /// Named first because it is the one the user can act on, and the only one
    /// that needs them to change their server.
    @Test func missingStoredPlaylistSupportNamesTheSetting() {
        let r = reason(stored: false)
        #expect(r?.contains("playlist_directory") == true)
        #expect(r?.contains("mpd.conf") == true)
    }

    @Test func emptyQueueAndSelfTargetAreRefused() {
        #expect(reason(queueEmpty: true) != nil)
        #expect(reason(target: "Living Room") != nil)
        #expect(reason(target: "") != nil)
    }

    /// cdda:/// URIs do not survive a stored playlist, and the disc is in one
    /// machine anyway — the target would get a queue that plays nothing.
    @Test func cdQueuesAreRefusedWithAReason() {
        #expect(reason(cd: true)?.contains("CD") == true)
    }

    @Test func serverConfigurationOutranksEveryOtherRefusal() {
        // If several apply, the one that needs a server change should be shown.
        #expect(reason(queueEmpty: true, cd: true, stored: false)?
                    .contains("playlist_directory") == true)
    }
}
