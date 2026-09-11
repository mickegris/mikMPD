// OggPacketDecoderTests.swift
// The simulator cannot be listened to, so this is where decoded audio is
// actually checked. The fixture is a synthetic tone — 440 Hz left, 554 Hz right —
// encoded to Opus by macOS's encoder and wrapped in Ogg pages by hand: an
// OpusHead page, an OpusTags page and three audio pages. No recorded music.
import Testing
import Foundation
import AVFoundation
@testable import mikMPD

private let toneFixture = Data(base64Encoded: "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")!

/// Header and audio packets from the fixture, via the real demuxer.
private func demuxTone() -> (OpusHeader, [[UInt8]]) {
    var d = OggDemuxer()
    d.push(toneFixture)
    var header: OpusHeader?
    var audio: [[UInt8]] = []
    var codec: OggCodec = .unknown
    while let p = d.nextPacket() {
        if p.startsStream {
            codec = OggCodecIdentifier.identify(firstPacket: p.data)
            if case .opus(let h) = codec { header = h }
        } else if !OggCodecIdentifier.isCommentHeader(p.data, codec: codec) {
            audio.append(p.data)
        }
    }
    return (header!, audio)
}

private func decodeAll(_ decoder: OggPacketDecoder, _ packets: [[UInt8]]) -> [AVAudioPCMBuffer] {
    packets.compactMap { decoder.decode($0) }
}

private func peak(_ buffers: [AVAudioPCMBuffer], channel: Int) -> Float {
    buffers.reduce(Float(0)) { best, b in
        guard let data = b.floatChannelData else { return best }
        var m = best
        for i in 0..<Int(b.frameLength) { m = max(m, abs(data[channel][i])) }
        return m
    }
}

@Suite struct OggPacketDecoderTests {

    @Test func fixtureIsWhatTheTestsAssume() {
        let (head, packets) = demuxTone()
        #expect(head.channels == 2)
        #expect(head.preSkip > 0)
        #expect(packets.count > 40)
    }

    /// The input callback once returned noErr with zero packets when its packet
    /// was spent, which tells AudioConverter the whole stream has ended. Decoding
    /// must keep producing audio for every packet, not just the first.
    @Test func everyPacketDecodesNotJustTheFirst() throws {
        let (head, packets) = demuxTone()
        let decoder = try #require(OggPacketDecoder(codec: .opus(head)))
        defer { decoder.close() }
        let buffers = decodeAll(decoder, packets)
        #expect(buffers.count >= packets.count - 1,
                "decoded \(buffers.count) of \(packets.count) packets")
        let frames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        #expect(frames >= (packets.count - 2) * 960 - head.preSkip)
    }

    /// The output format is non-interleaved, so stereo is two AudioBuffers. A
    /// copied AudioBufferList struct holds only one, and the right channel was
    /// written past its end. Both channels of the tone must carry signal.
    @Test func bothChannelsCarryTheTone() throws {
        let (head, packets) = demuxTone()
        let decoder = try #require(OggPacketDecoder(codec: .opus(head)))
        defer { decoder.close() }
        let buffers = decodeAll(decoder, packets)
        #expect(decoder.format.channelCount == 2)
        #expect(!decoder.format.isInterleaved)
        #expect(peak(buffers, channel: 0) > 0.2, "left channel is silent")
        #expect(peak(buffers, channel: 1) > 0.2, "right channel is silent")
    }

    /// RFC 7845: exactly preSkip samples are dropped, once, from the front.
    @Test func preSkipIsRemovedExactlyOnce() throws {
        let (head, packets) = demuxTone()
        var noSkipHead = head
        noSkipHead.preSkip = 0
        let withSkip = try #require(OggPacketDecoder(codec: .opus(head)))
        let withoutSkip = try #require(OggPacketDecoder(codec: .opus(noSkipHead)))
        defer { withSkip.close(); withoutSkip.close() }
        let a = decodeAll(withSkip, packets).reduce(0) { $0 + Int($1.frameLength) }
        let b = decodeAll(withoutSkip, packets).reduce(0) { $0 + Int($1.frameLength) }
        #expect(b - a == head.preSkip)
    }

    @Test func vorbisAndUnknownGetNoDecoder() {
        #expect(OggPacketDecoder(codec: .vorbis) == nil)
        #expect(OggPacketDecoder(codec: .unknown) == nil)
    }

    @Test func aClosedDecoderDecodesNothing() throws {
        let (head, packets) = demuxTone()
        let decoder = try #require(OggPacketDecoder(codec: .opus(head)))
        decoder.close()
        #expect(decoder.decode(packets[0]) == nil)
        decoder.close()   // idempotent
    }
}

@Suite struct PhoneStreamRouteActionTests {
    /// Unplugging headphones left the engine stopped, no sound anywhere, and the
    /// button still reading "Streaming to phone".
    @Test func unpluggingHeadphonesStopsTheStream() {
        #expect(phoneStreamRouteAction(for: .oldDeviceUnavailable, oggPlayerActive: true) == .stop)
        #expect(phoneStreamRouteAction(for: .oldDeviceUnavailable, oggPlayerActive: false) == .stop)
    }

    /// AVAudioEngine stops when a device arrives too; AVPlayer copes by itself.
    @Test func aNewDeviceRestartsOnlyTheOggStream() {
        #expect(phoneStreamRouteAction(for: .newDeviceAvailable, oggPlayerActive: true) == .restartOggStream)
        #expect(phoneStreamRouteAction(for: .newDeviceAvailable, oggPlayerActive: false) == .ignore)
    }

    /// Starting a stream changes the session category; reacting to that would
    /// restart the stream in a loop.
    @Test func categoryAndOtherChangesAreIgnored() {
        let reasons: [AVAudioSession.RouteChangeReason] =
            [.categoryChange, .override, .wakeFromSleep, .routeConfigurationChange, .unknown]
        for reason in reasons {
            #expect(phoneStreamRouteAction(for: reason, oggPlayerActive: true) == .ignore)
        }
    }
}
