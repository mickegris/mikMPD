// OggStreamingTests.swift
// v1.7.1 review of Ogg phone streaming. The player itself needs a network and an
// audio device; everything it decides is pulled out as pure functions and
// tested here, and FLAC is decoded for real from generated fixtures.
import Testing
import Foundation
import AVFoundation
@testable import mikMPD

// MARK: - FLAC decoding

/// Every bitstream in `data`: its codec and decoded audio buffers.
private func decodeStreams(_ data: Data) -> [(codec: OggCodec, format: AVAudioFormat?, buffers: [AVAudioPCMBuffer])] {
    var d = OggDemuxer()
    d.push(data)
    var out: [(codec: OggCodec, format: AVAudioFormat?, buffers: [AVAudioPCMBuffer])] = []
    var decoder: OggPacketDecoder?
    var codec: OggCodec = .unknown
    while let p = d.nextPacket() {
        if p.startsStream {
            decoder?.close()
            codec = OggCodecIdentifier.identify(firstPacket: p.data)
            decoder = OggPacketDecoder(codec: codec)
            out.append((codec, decoder?.format, []))
        } else if !OggCodecIdentifier.isCommentHeader(p.data, codec: codec),
                  let b = decoder?.decode(p.data) {
            out[out.count - 1].buffers.append(b)
        }
    }
    decoder?.close()
    return out
}

/// Frequency of a channel's tone, from its zero crossings — the check that the
/// audio plays at the right speed, which a simulator cannot be listened to for.
private func toneFrequency(_ buffers: [AVAudioPCMBuffer], channel: Int, rate: Double) -> Double {
    var crossings = 0, frames = 0
    var previous: Float = 0
    for b in buffers {
        guard let data = b.floatChannelData else { continue }
        for i in 0..<Int(b.frameLength) {
            let v = data[channel][i]
            if previous < 0, v >= 0 { crossings += 1 }
            previous = v
        }
        frames += Int(b.frameLength)
    }
    return Double(crossings) / (Double(frames) / rate)
}

@Suite struct OggFLACDecodeTests {

    /// v1.7 built every FLAC decoder with frames-per-packet 0, which
    /// AudioConverterNew refuses: Ogg FLAC never played at all.
    @Test(arguments: [(oggFLAC44k1, 44100.0), (oggFLAC48k, 48000.0)])
    func decodesAtTheStreamsOwnRate(fixture: Data, rate: Double) throws {
        let streams = decodeStreams(fixture)
        try #require(streams.count == 1)
        let s = streams[0]
        let format = try #require(s.format, "no decoder for \(s.codec)")
        #expect(format.sampleRate == rate)
        #expect(format.channelCount == 2)
        let frames = s.buffers.reduce(0) { $0 + Int($1.frameLength) }
        #expect(abs(frames - Int(rate * 0.3)) < 64, "decoded \(frames) frames")
    }

    /// The "9 % fast" bug: 44.1 kHz decoded as 48 kHz raises a 1 kHz tone to ~1088 Hz.
    @Test(arguments: [(oggFLAC44k1, 44100.0), (oggFLAC48k, 48000.0)])
    func tonesComeOutAtTheirTrueFrequency(fixture: Data, rate: Double) throws {
        let s = try #require(decodeStreams(fixture).first)
        let playbackRate = try #require(s.format).sampleRate
        let left = toneFrequency(s.buffers, channel: 0, rate: playbackRate)
        let right = toneFrequency(s.buffers, channel: 1, rate: playbackRate)
        #expect(abs(left - 1000) < 20, "left at \(left) Hz")
        #expect(abs(right - 1500) < 30, "right at \(right) Hz")
        _ = rate
    }

    /// A chained stream whose rate changes at the boundary — what MPD's FLAC
    /// encoder sends between a CD rip and a 48 kHz file. Both halves decode, each
    /// at its own rate, so the player reconfigures exactly once, there.
    @Test func aRateChangeAtATrackBoundaryIsFollowed() throws {
        let streams = decodeStreams(oggFLACChain)
        try #require(streams.count == 2)
        #expect(streams[0].format?.sampleRate == 44100)
        #expect(streams[1].format?.sampleRate == 48000)
        #expect(streams[0].format != streams[1].format)
        for s in streams { #expect(!s.buffers.isEmpty) }
    }
}

@Suite struct EngineFormatReuseTests {
    /// The premise of configuring the engine per *format* rather than per
    /// bitstream: two Opus bitstreams (two songs) produce equal formats, so a
    /// track change never touches the engine.
    @Test func sameCodecSameChannelsSameFormat() throws {
        let head = OpusHeader(channels: 2, preSkip: 312, inputSampleRate: 44100, outputGain: 0, mappingFamily: 0)
        let a = try #require(OggPacketDecoder(codec: .opus(head)))
        let b = try #require(OggPacketDecoder(codec: .opus(head)))
        defer { a.close(); b.close() }
        #expect(a.format == b.format)
    }

    @Test func monoToStereoIsAFormatChange() throws {
        let mono = OpusHeader(channels: 1, preSkip: 312, inputSampleRate: 48000, outputGain: 0, mappingFamily: 0)
        let stereo = OpusHeader(channels: 2, preSkip: 312, inputSampleRate: 48000, outputGain: 0, mappingFamily: 0)
        let a = try #require(OggPacketDecoder(codec: .opus(mono)))
        let b = try #require(OggPacketDecoder(codec: .opus(stereo)))
        defer { a.close(); b.close() }
        #expect(a.format != b.format)
    }
}

// MARK: - Buffering

@Suite struct OggBufferPolicyTests {
    let policy = OggBufferPolicy(sampleRate: 48000)

    @Test func startsOnlyWithTwoSecondsBuffered() {
        #expect(!policy.shouldStart(bufferedFrames: 48000))
        #expect(policy.shouldStart(bufferedFrames: 96000))
    }

    /// v1.7 had no underrun state: a dry buffer played silence, then stuttered.
    @Test func runningDryIsAnUnderrun() {
        #expect(policy.isUnderrun(bufferedFrames: 0))
        #expect(policy.isUnderrun(bufferedFrames: 12000))
        #expect(!policy.isUnderrun(bufferedFrames: 24000))
    }

    /// Hysteresis: resuming needs the full start level, not just "above low",
    /// or it would pause and resume on every packet.
    @Test func recoveryNeedsTheStartLevelNotJustAboveLow() {
        let justAboveLow = 12001
        #expect(!policy.isUnderrun(bufferedFrames: justAboveLow))
        #expect(!policy.shouldStart(bufferedFrames: justAboveLow))
    }

    /// Latency is bounded: after a stall the backlog is dropped, not queued.
    @Test func dropsWhatWouldExceedSixSeconds() {
        #expect(policy.accepts(incomingFrames: 4800, bufferedFrames: 280000))
        #expect(!policy.accepts(incomingFrames: 4800, bufferedFrames: 286000))
    }

    @Test func scalesWithTheSampleRate() {
        let cd = OggBufferPolicy(sampleRate: 44100)
        #expect(cd.startFrames == 88200)
        #expect(cd.maxFrames == 264600)
    }
}

// MARK: - Reconnecting

@Suite struct OggReconnectTests {
    @Test func fourTriesThenGiveUp() {
        #expect((1...5).map(oggReconnectDelay) == [1, 2, 4, 8, nil])
    }

    @Test func networkBlipsAreRetried() {
        for code: URLError.Code in [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                                    .cannotConnectToHost] {
            #expect(oggStreamErrorIsTransient(code), "\(code)")
        }
    }

    @Test func whatRetryingCannotFixIsNot() {
        for code: URLError.Code in [.badURL, .unsupportedURL, .cancelled, .userAuthenticationRequired] {
            #expect(!oggStreamErrorIsTransient(code), "\(code)")
        }
    }
}

@Suite struct OggStallTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// An engine stopped under the player looks like this: "playing", but
    /// nothing has been heard for seconds.
    @Test func playingWithNothingPlayedBackIsAStall() {
        #expect(oggStreamStalled(lastPlayedBack: t0, now: t0.addingTimeInterval(3.5), state: .playing))
        #expect(!oggStreamStalled(lastPlayedBack: t0, now: t0.addingTimeInterval(1), state: .playing))
    }

    /// Those states are already dealing with it.
    @Test func bufferingOrReconnectingIsNeverAStall() {
        for state: OggStreamState in [.buffering, .reconnecting(attempt: 1), .suspended, .idle] {
            #expect(!oggStreamStalled(lastPlayedBack: t0, now: t0.addingTimeInterval(60), state: state))
        }
    }
}

@Suite struct OggStreamStateLifecycleTests {
    /// Reconnecting keeps the feature on; only the spent budget (.failed) or an
    /// explicit stop (.idle) ends it.
    @Test func reconnectingAndSuspendedDoNotEndThePhoneStream() {
        #expect(!OggStreamState.reconnecting(attempt: 2).endsPhoneStream)
        #expect(!OggStreamState.suspended.endsPhoneStream)
    }

    @Test func reconnectingCountsAsLiveButSuspendedDoesNot() {
        #expect(OggStreamState.reconnecting(attempt: 1).isRendering)
        #expect(!OggStreamState.suspended.isRendering)
    }
}

@Suite struct PhoneStreamInterruptionTests {
    @Test func anInterruptionSuspends() {
        #expect(phoneStreamInterruptionAction(type: .began, options: []) == .suspend)
    }

    @Test func itsEndResumesOnlyWhenIOSSaysSo() {
        #expect(phoneStreamInterruptionAction(type: .ended, options: .shouldResume) == .resume)
        #expect(phoneStreamInterruptionAction(type: .ended, options: []) == .ignore)
    }
}
