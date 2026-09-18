// QueueTransferTests.swift
// The transfer itself is I/O, but the decisions inside it are not — and the
// ordering bug it guards against is invisible without two partitions and a
// stopwatch, which is exactly why these are pure functions.
import Testing
import Foundation
@testable import mikMPD

@Suite struct TransferStartCommandTests {
    /// One command starts the target at the right song and position.
    @Test func playingStartsAtThePositionInOneCommand() {
        #expect(transferStartCommand(state: .playing, pos: 4, elapsed: 61.5) == "seek 4 61.500")
        #expect(transferFinishCommands(state: .playing).isEmpty)
    }

    /// A paused source still starts the target, so its outputs are proven to
    /// open, and is paused only afterwards.
    @Test func pausedStartsThenPausesOnceConfirmed() {
        #expect(transferStartCommand(state: .paused, pos: 2, elapsed: 30) == "seek 2 30.000")
        #expect(transferFinishCommands(state: .paused) == ["pause 1"])
    }

    @Test func atTheStartOfATrackPlayIsEnough() {
        #expect(transferStartCommand(state: .playing, pos: 0, elapsed: 0.2) == "play 0")
    }

    @Test func stoppedStartsNothing() {
        #expect(transferStartCommand(state: .stopped, pos: 3, elapsed: 12) == nil)
        #expect(transferFinishCommands(state: .stopped).isEmpty)
    }

    /// playlistPos is -1 when nothing is current.
    @Test func noCurrentSongStartsNothing() {
        #expect(transferStartCommand(state: .playing, pos: -1, elapsed: 10) == nil)
    }

    /// The sequence that aborted MPD sent `seekcur` straight after `play`, while
    /// the target's outputs were still opening. No step here seeks separately.
    @Test func neverSeeksAsASeparateStep() {
        for state in [TransferPlaybackState.playing, .paused] {
            #expect(transferStartCommand(state: state, pos: 5, elapsed: 90)?.hasPrefix("seekcur") == false)
            #expect(!transferFinishCommands(state: state).contains { $0.hasPrefix("seek") })
        }
    }
}

@Suite struct TransferStartOutcomeTests {
    private func status(_ state: String, _ elapsed: String, error: String? = nil) -> [String: String] {
        var d = ["state": state, "elapsed": elapsed]
        if let error { d["error"] = error }
        return d
    }

    /// Verified on 0.24.0: from `seek 2 42.0`, elapsed read 42.000, 42.205, 42.410…
    @Test func playingWithElapsedAdvancingIsSuccess() {
        #expect(transferStartOutcome(previous: status("play", "42.000"),
                                     current: status("play", "42.205")) == .playing)
    }

    /// `state: play` alone is not trusted.
    @Test func playWithoutProgressIsNotYetSuccess() {
        #expect(transferStartOutcome(previous: nil, current: status("play", "42.0")) == .pending)
        #expect(transferStartOutcome(previous: status("play", "42.0"),
                                     current: status("play", "42.0")) == .pending)
    }

    /// The error MPD logged for the switched-off DAC.
    @Test func anErrorLineIsFailure() {
        let msg = #"Failed to open "E30 II" (alsa); Failed to open ALSA device "hw:CARD=II,DEV=0": No such device"#
        #expect(transferStartOutcome(previous: status("play", "0.1"),
                                     current: status("pause", "0.1", error: msg)) == .failed(msg))
    }

    @Test func notPlayingYetIsPending() {
        #expect(transferStartOutcome(previous: nil, current: status("stop", "0")) == .pending)
    }
}

@Suite struct TransferTargetOutputsTests {
    @Test func noEnabledOutputsIsRefusedWhenSomethingWouldPlay() {
        #expect(transferTargetOutputsRefusal(target: "airplay", enabledOutputs: [], willPlay: true)?
                    .contains("airplay") == true)
    }

    @Test func aStoppedQueueCanLandAnywhere() {
        #expect(transferTargetOutputsRefusal(target: "airplay", enabledOutputs: [], willPlay: false) == nil)
    }

    @Test func anEnabledOutputIsEnough() {
        #expect(transferTargetOutputsRefusal(target: "default", enabledOutputs: ["E30 II"], willPlay: true) == nil)
    }
}

@Suite struct PartitionSummaryTests {
    @Test func countsOnlyRealEnabledOutputs() {
        let outputs: [[String: String]] = [
            ["outputname": "E30 II",     "plugin": "alsa",  "outputenabled": "1"],
            ["outputname": "Denon HDMI", "plugin": "alsa",  "outputenabled": "0"],
            ["outputname": "http opus",  "plugin": "dummy", "outputenabled": "1"],
        ]
        let s = PartitionSummary(name: "default",
                                 status: ["state": "pause", "playlistlength": "13"],
                                 outputs: outputs)
        #expect(s.enabledOutputs == ["E30 II"])
        #expect(s.stateLabel == "Paused")
        #expect(s.queueLength == 13)
    }

    @Test func anEmptyStoppedPartitionReadsEmpty() {
        let s = PartitionSummary(name: "airplay", status: ["state": "stop", "playlistlength": "0"], outputs: [])
        #expect(s.stateLabel == "Empty")
        #expect(s.enabledOutputs.isEmpty)
    }

    @Test func aStoppedPartitionWithAQueueReadsStopped() {
        let s = PartitionSummary(name: "http", status: ["state": "stop", "playlistlength": "364"], outputs: [])
        #expect(s.stateLabel == "Stopped")
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

@Suite struct TransferDriftCompensationTests {
    /// The source keeps playing while the queue is saved, loaded and started, so
    /// resuming at the position read beforehand drops the music backwards by the
    /// length of the transfer.
    @Test func playingSourceIsAdvancedByTheTransferTime() {
        #expect(transferCompensatedElapsed(elapsed: 60, transferSeconds: 0.4,
                                           duration: 300, state: .playing) == 60.4)
    }

    /// A paused source did not advance, so compensating would push it forward
    /// past where the user left it.
    @Test func pausedAndStoppedSourcesAreNeverCompensated() {
        #expect(transferCompensatedElapsed(elapsed: 60, transferSeconds: 5,
                                           duration: 300, state: .paused) == 60)
        #expect(transferCompensatedElapsed(elapsed: 60, transferSeconds: 5,
                                           duration: 300, state: .stopped) == 60)
    }

    /// Seeking past the end would skip the track the user was listening to —
    /// worse than a little drift. A slow save/load on a long queue makes this
    /// reachable near the end of a track.
    @Test func neverSeeksPastTheEndOfTheTrack() {
        let v = transferCompensatedElapsed(elapsed: 299.9, transferSeconds: 3,
                                           duration: 300, state: .playing)
        #expect(v < 300)
        #expect(v == 299.75)
    }

    @Test func unknownDurationStillCompensates() {
        // Radio streams report no duration; there is no end to overshoot.
        #expect(transferCompensatedElapsed(elapsed: 12, transferSeconds: 0.5,
                                           duration: 0, state: .playing) == 12.5)
    }

    @Test func negativeInputsAreClamped() {
        #expect(transferCompensatedElapsed(elapsed: -5, transferSeconds: -1,
                                           duration: 300, state: .playing) == 0)
    }

    /// A fast LAN transfer should be imperceptible rather than rounded away.
    @Test func smallTransfersAreStillAccountedFor() {
        #expect(transferCompensatedElapsed(elapsed: 100, transferSeconds: 0.05,
                                           duration: 300, state: .playing) == 100.05)
    }
}

/// Consume, crossfade, MixRamp and ReplayGain belong to the partition. A transfer
/// must leave them alone on both sides — v1.7 copied the source's consume onto
/// the target, which is what the user noticed.
@Suite struct PartitionSettingsTests {
    private func settings(_ status: [String: String], gain: String? = "off") -> PartitionSettings {
        PartitionSettings(status: status, replayGainStatus: gain.map { ["replay_gain_mode": $0] })
    }

    @Test func absentXfadeMeansZero() {
        #expect(settings(["consume": "1"]).crossfade == 0)
        #expect(settings(["xfade": "5"]).crossfade == 5)
    }

    @Test func oneshotConsumeIsKeptRaw() {
        #expect(settings(["consume": "oneshot"]).consume == "oneshot")
    }

    @Test func nanMixrampDelayMeansOff() {
        #expect(settings(["mixrampdelay": "nan"]).mixrampDelay == nil)
        #expect(settings([:]).mixrampDelay == nil)
        #expect(settings(["mixrampdelay": "2.5"]).mixrampDelay == 2.5)
    }

    @Test func replayGainComesFromItsOwnRecord() {
        #expect(settings([:], gain: "album").replayGainMode == "album")
        #expect(settings([:], gain: nil).replayGainMode == nil)
    }

    @Test func noDriftWhenEqual() {
        let a = settings(["consume": "1", "xfade": "5", "mixrampdb": "0.000000"], gain: "track")
        #expect(a.drift(to: a).isEmpty)
        #expect(a.restoreCommands(from: a).isEmpty)
    }

    @Test func driftNamesEveryChangedSettingInAFixedOrder() {
        let before = settings(["consume": "1", "xfade": "5"], gain: "track")
        let after = settings(["consume": "0"], gain: "off")
        #expect(before.drift(to: after) == ["Consume", "Crossfade", "ReplayGain"])
    }

    @Test func restoreSendsOnlyTheDriftedSettings() {
        let before = settings(["consume": "1", "xfade": "5"], gain: "track")
        let after = settings(["consume": "0", "xfade": "5"], gain: "track")
        #expect(before.restoreCommands(from: after) == ["consume 1"])
    }

    @Test func restoreQuotesTheReplayGainMode() {
        let before = settings([:], gain: "album")
        let after = settings([:], gain: "off")
        #expect(before.restoreCommands(from: after) == ["replay_gain_mode \"album\""])
    }

    @Test func restoringMixrampOffSendsNan() {
        let before = settings(["mixrampdb": "0"])
        let after = settings(["mixrampdb": "0", "mixrampdelay": "3"])
        #expect(before.restoreCommands(from: after) == ["mixrampdb 0.0", "mixrampdelay nan"])
    }

    /// An unreadable ReplayGain mode is never "restored" to nothing.
    @Test func unknownReplayGainIsNeverDrift() {
        let before = settings([:], gain: nil)
        let after = settings([:], gain: "album")
        #expect(before.drift(to: after).isEmpty)
        #expect(after.drift(to: before).isEmpty)
    }

    /// A float written back must not read as drift because of its last decimal.
    @Test func floatsCompareWithTolerance() {
        let before = settings(["mixrampdb": "-17.5"])
        let after = settings(["mixrampdb": "-17.500000"])
        #expect(before.drift(to: after).isEmpty)
    }

    @Test func notesNameThePartitionAndOutcome() {
        #expect(transferSettingsNote(partition: "Kitchen", drift: [], repaired: true) == nil)
        #expect(transferSettingsNote(partition: "Kitchen", drift: ["Consume"], repaired: true)
                == "Kitchen: Consume changed during the move and was put back.")
        #expect(transferSettingsNote(partition: "Kitchen", drift: ["Consume", "Crossfade"], repaired: false)
                == "Kitchen: Consume, Crossfade changed during the move and could not be put back.")
    }
}

@Suite struct TransferTargetSetupTests {
    private let status = ["repeat": "1", "random": "1", "single": "oneshot", "consume": "1",
                          "xfade": "5", "mixrampdb": "0", "state": "play"]

    /// The regression test for the reported bug: nothing partition-owned is sent.
    @Test func neverSendsPartitionOwnedSettings() {
        let setup = transferTargetSetupCommands(target: "Kitchen", scratchPlaylist: ".mikmpd-transfer-1",
                                                sourceStatus: status)
        for cmd in setup.required + setup.bestEffort {
            for owned in ["consume", "crossfade", "mixramp", "replay_gain"] {
                #expect(!cmd.hasPrefix(owned), "sent \(cmd)")
            }
        }
    }

    @Test func buildsTheTargetBeforeAnythingElse() {
        let setup = transferTargetSetupCommands(target: "Kit\"chen", scratchPlaylist: ".mikmpd-transfer-1",
                                                sourceStatus: status)
        #expect(setup.required == ["partition \"Kit\\\"chen\"", "clear", "load \".mikmpd-transfer-1\""])
    }

    /// Repeat/random/single travel with the queue, raw — so oneshot survives.
    @Test func queueModesTravelRaw() {
        #expect(transferQueueModeCommands(sourceStatus: status) == ["repeat 1", "random 1", "single oneshot"])
    }

    @Test func missingModesAreNotInvented() {
        #expect(transferQueueModeCommands(sourceStatus: [:]).isEmpty)
    }
}

@Suite struct TransferResultTests {
    @Test func cleanMoveNeedsNoAlert() {
        #expect(!TransferResult().needsAttention)
    }

    @Test func notesAloneReportAMove() {
        let r = TransferResult(notes: ["Kitchen: Consume changed during the move and was put back."])
        #expect(r.needsAttention)
        #expect(r.alertTitle == "Playback Moved")
    }

    @Test func failureLeadsTheMessage() {
        let r = TransferResult(failure: "No.", notes: ["A note."])
        #expect(r.alertTitle == "Could Not Move Playback")
        #expect(r.alertMessage == "No.\n\nA note.")
    }
}
