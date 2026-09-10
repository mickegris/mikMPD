// OggDemuxerTests.swift
// The demuxer is pure — bytes in, packets out — so it can be tested
// exhaustively without a server or a device, which is most of why it exists in
// this shape. The builder below emits real Ogg pages; the page construction is
// the same one that produced a fixture macOS validated as genuine Ogg Opus.
import Testing
import Foundation
@testable import mikMPD

// MARK: - Test stream builder

/// Builds real Ogg bitstreams, including deliberately awkward pagings.
struct OggStreamBuilder {
    var serial: UInt32 = 0x1234_5678
    var sequence: UInt32 = 0

    /// One page carrying `packets`, laced per spec.
    mutating func page(_ packets: [[UInt8]], granule: Int64,
                       bos: Bool = false, eos: Bool = false,
                       continued: Bool = false) -> [UInt8] {
        var segs: [UInt8] = []
        for p in packets {
            var n = p.count
            while n >= 255 { segs.append(255); n -= 255 }
            segs.append(UInt8(n))
        }
        precondition(segs.count <= 255, "too many segments for one page")
        var page: [UInt8] = Array("OggS".utf8)
        page.append(0)
        page.append((continued ? 1 : 0) | (bos ? 2 : 0) | (eos ? 4 : 0))
        let g = UInt64(bitPattern: granule)
        for i in 0..<8 { page.append(UInt8((g >> (8 * UInt64(i))) & 0xFF)) }
        for i in 0..<4 { page.append(UInt8((serial   >> (8 * UInt32(i))) & 0xFF)) }
        for i in 0..<4 { page.append(UInt8((sequence >> (8 * UInt32(i))) & 0xFF)) }
        page.append(contentsOf: [0, 0, 0, 0])          // CRC placeholder
        page.append(UInt8(segs.count))
        page.append(contentsOf: segs)
        for p in packets { page.append(contentsOf: p) }
        let crc = OggDemuxer.crc32(page)
        page[22] = UInt8(crc & 0xFF); page[23] = UInt8((crc >> 8) & 0xFF)
        page[24] = UInt8((crc >> 16) & 0xFF); page[25] = UInt8((crc >> 24) & 0xFF)
        sequence += 1
        return page
    }

    /// A page carrying a raw body with an explicit lacing table — the only way
    /// to express a packet deliberately left unterminated across a page break.
    mutating func rawPage(segments: [UInt8], body: [UInt8], granule: Int64,
                          bos: Bool = false, eos: Bool = false, continued: Bool = false) -> [UInt8] {
        var page: [UInt8] = Array("OggS".utf8)
        page.append(0)
        page.append((continued ? 1 : 0) | (bos ? 2 : 0) | (eos ? 4 : 0))
        let g = UInt64(bitPattern: granule)
        for i in 0..<8 { page.append(UInt8((g >> (8 * UInt64(i))) & 0xFF)) }
        for i in 0..<4 { page.append(UInt8((serial   >> (8 * UInt32(i))) & 0xFF)) }
        for i in 0..<4 { page.append(UInt8((sequence >> (8 * UInt32(i))) & 0xFF)) }
        page.append(contentsOf: [0, 0, 0, 0])
        page.append(UInt8(segments.count))
        page.append(contentsOf: segments)
        page.append(contentsOf: body)
        let crc = OggDemuxer.crc32(page)
        page[22] = UInt8(crc & 0xFF); page[23] = UInt8((crc >> 8) & 0xFF)
        page[24] = UInt8((crc >> 16) & 0xFF); page[25] = UInt8((crc >> 24) & 0xFF)
        sequence += 1
        return page
    }
}

func opusHeadPacket(channels: Int = 2, preSkip: Int = 312, rate: Int = 48000) -> [UInt8] {
    var p: [UInt8] = Array("OpusHead".utf8)
    p.append(1); p.append(UInt8(channels))
    p.append(UInt8(preSkip & 0xFF)); p.append(UInt8((preSkip >> 8) & 0xFF))
    for i in 0..<4 { p.append(UInt8((rate >> (8 * i)) & 0xFF)) }
    p.append(0); p.append(0)   // output gain
    p.append(0)                // mapping family
    return p
}

let opusTagsPacket: [UInt8] = Array("OpusTags".utf8) + [4,0,0,0] + Array("mpd\0".utf8) + [0,0,0,0]

/// Deterministic pseudo-random payload, so a failure is reproducible.
func payload(_ seed: UInt8, _ count: Int) -> [UInt8] {
    var v = seed == 0 ? 1 : seed
    return (0..<count).map { _ in v = v &* 31 &+ 17; return v }
}

func drain(_ d: inout OggDemuxer) -> [OggPacket] {
    var out: [OggPacket] = []
    while let p = d.nextPacket() { out.append(p) }
    return out
}

// MARK: - CRC

@Suite struct OggCRCTests {
    // Ogg uses polynomial 0x04c11db7 with init 0, no reflection and no final
    // xor — NOT the zlib variant, whose check value for this input is a
    // different number entirely. A reflected implementation makes every page
    // look corrupt, which presents as "no audio" rather than as a checksum bug,
    // so the value is pinned here. It is cross-checked against the generator
    // that produced an Ogg Opus file `afinfo` accepted as genuine.
    @Test func knownVector() {
        #expect(OggDemuxer.crc32(Array("123456789".utf8)) == 0x89A1_897F)
    }

    @Test func emptyInputIsZero() {
        #expect(OggDemuxer.crc32([]) == 0)
    }

    @Test func builtPagePassesValidation() {
        var b = OggStreamBuilder()
        let page = b.page([payload(1, 40)], granule: 960)
        #expect(OggDemuxer.crcIsValid(page))
    }

    @Test func flippedByteFailsValidation() {
        var b = OggStreamBuilder()
        var page = b.page([payload(1, 40)], granule: 960)
        page[page.count - 1] ^= 0xFF
        #expect(!OggDemuxer.crcIsValid(page))
    }
}

// MARK: - Packet extraction

@Suite struct OggDemuxerTests {
    @Test func singlePageSinglePacket() {
        var b = OggStreamBuilder()
        var d = OggDemuxer()
        let body = payload(7, 100)
        d.push(b.page([body], granule: 960, bos: true))
        let out = drain(&d)
        #expect(out.count == 1)
        #expect(out.first?.data == body)
        #expect(out.first?.granulePosition == 960)
        #expect(out.first?.startsStream == true)
    }

    @Test func multiplePacketsInOnePage() {
        var b = OggStreamBuilder()
        var d = OggDemuxer()
        let ps = [payload(1, 10), payload(2, 20), payload(3, 30)]
        d.push(b.page(ps, granule: 2880))
        #expect(drain(&d).map(\.data) == ps)
    }

    /// A 255-byte packet needs a 255 lacing value *and* a terminating 0 —
    /// the classic off-by-one in every hand-written Ogg parser.
    @Test func packetOfExactly255Bytes() {
        var b = OggStreamBuilder()
        var d = OggDemuxer()
        let p = payload(9, 255)
        d.push(b.page([p], granule: 960))
        let out = drain(&d)
        #expect(out.count == 1)
        #expect(out.first?.data.count == 255)
    }

    @Test func longPacketWithMultipleLacingRuns() {
        var b = OggStreamBuilder()
        var d = OggDemuxer()
        let p = payload(11, 255 * 3 + 7)
        d.push(b.page([p], granule: 960))
        #expect(drain(&d).first?.data == p)
    }

    @Test func zeroLengthPacket() {
        var b = OggStreamBuilder()
        var d = OggDemuxer()
        d.push(b.page([[], payload(4, 12)], granule: 960))
        let out = drain(&d)
        #expect(out.count == 2)
        #expect(out[0].data.isEmpty)
        #expect(out[1].data.count == 12)
    }

    @Test func packetSpanningTwoPages() {
        var b = OggStreamBuilder()
        var d = OggDemuxer()
        // A page leaves a packet open only if its last lacing value is 255 —
        // anything smaller terminates it. 765 = 255 * 3, so nothing terminates.
        let whole = payload(13, 765)
        d.push(b.rawPage(segments: [255, 255, 255], body: whole, granule: -1, bos: true))
        #expect(drain(&d).isEmpty)   // nothing complete yet
        d.push(b.rawPage(segments: [5], body: payload(14, 5), granule: 960, continued: true))
        let out = drain(&d)
        #expect(out.count == 1)
        #expect(out.first?.data == whole + payload(14, 5))
        #expect(out.first?.granulePosition == 960)
    }

    @Test func packetSpanningThreePages() {
        var b = OggStreamBuilder()
        var d = OggDemuxer()
        let a = payload(1, 510), c = payload(2, 510), e = payload(3, 20)
        d.push(b.rawPage(segments: [255, 255], body: a, granule: -1, bos: true))
        d.push(b.rawPage(segments: [255, 255], body: c, granule: -1, continued: true))
        d.push(b.rawPage(segments: [20], body: e, granule: 1920, continued: true))
        let out = drain(&d)
        #expect(out.count == 1)
        #expect(out.first?.data == a + c + e)
    }

    /// The property that catches most incremental-parser bugs: how the bytes
    /// were divided into chunks must not change the packets that come out.
    @Test func byteAtATimeMatchesOneShot() {
        var b = OggStreamBuilder()
        var stream: [UInt8] = []
        stream += b.page([opusHeadPacket()], granule: 0, bos: true)
        stream += b.page([opusTagsPacket], granule: 0)
        stream += b.page([payload(1, 100), payload(2, 300)], granule: 1920)
        stream += b.page([payload(3, 255)], granule: 2880, eos: true)

        var oneShot = OggDemuxer(); oneShot.push(stream)
        let a = drain(&oneShot)

        var perByte = OggDemuxer()
        var bs: [OggPacket] = []
        for byte in stream { perByte.push([byte]); while let p = perByte.nextPacket() { bs.append(p) } }

        #expect(a.map(\.data) == bs.map(\.data))
        #expect(a.map(\.granulePosition) == bs.map(\.granulePosition))
        #expect(a.count == 5)   // OpusHead, OpusTags, two audio, one audio
    }

    @Test func oddChunkSizesMatchOneShot() {
        var b = OggStreamBuilder()
        var stream: [UInt8] = []
        for i in 0..<8 { stream += b.page([payload(UInt8(i + 1), 50 * (i + 1))], granule: Int64(960 * (i + 1))) }
        var oneShot = OggDemuxer(); oneShot.push(stream)
        let expected = drain(&oneShot).map(\.data)

        for chunk in [1, 3, 7, 13, 64, 999, 4096] {
            var d = OggDemuxer(); var got: [[UInt8]] = []
            var i = 0
            while i < stream.count {
                let end = min(i + chunk, stream.count)
                d.push(Array(stream[i..<end]))
                while let p = d.nextPacket() { got.append(p.data) }
                i = end
            }
            #expect(got == expected, "chunk size \(chunk)")
        }
    }
}

// MARK: - Live-stream behaviour

@Suite struct OggResyncTests {
    /// We join MPD's httpd mid-stream, so the first bytes are almost never a
    /// page boundary. Every possible starting offset must recover.
    @Test func joiningMidStreamRecovers() {
        var b = OggStreamBuilder()
        var stream: [UInt8] = []
        for i in 0..<6 { stream += b.page([payload(UInt8(i + 1), 80)], granule: Int64(960 * (i + 1))) }
        let firstPageSize = 27 + 1 + 80

        for offset in 0..<firstPageSize {
            var d = OggDemuxer()
            d.push(Array(stream[offset...]))
            let out = drain(&d)
            // Offset 0 gets all six; any later offset loses only the first page.
            #expect(out.count == (offset == 0 ? 6 : 5), "offset \(offset)")
            #expect(out.last?.data == payload(6, 80))
        }
    }

    /// "OggS" inside packet payload must not be mistaken for a page start.
    /// The CRC check is the only thing that makes scanning safe.
    @Test func capturePatternInsidePayloadDoesNotDesync() {
        var b = OggStreamBuilder()
        var d = OggDemuxer()
        var evil: [UInt8] = payload(5, 20)
        evil += Array("OggS".utf8)
        evil += [0, 0, 0, 0, 0, 0, 0, 0]
        evil += payload(6, 40)
        d.push(b.page([evil], granule: 960, bos: true))
        d.push(b.page([payload(7, 30)], granule: 1920))
        let out = drain(&d)
        #expect(out.count == 2)
        #expect(out[0].data == evil)
        #expect(out[1].data == payload(7, 30))
    }

    @Test func corruptedPageIsSkippedAndStreamResyncs() {
        var b = OggStreamBuilder()
        var stream = b.page([payload(1, 60)], granule: 960, bos: true)
        var bad = b.page([payload(2, 60)], granule: 1920)
        bad[40] ^= 0xFF                                   // corrupt the body
        stream += bad
        stream += b.page([payload(3, 60)], granule: 2880)

        var d = OggDemuxer()
        d.push(stream)
        let out = drain(&d)
        #expect(out.map(\.data) == [payload(1, 60), payload(3, 60)])
    }

    @Test func truncatedFinalPageYieldsNothingPartial() {
        var b = OggStreamBuilder()
        let full = b.page([payload(1, 200)], granule: 960, bos: true)
        var d = OggDemuxer()
        d.push(Array(full[0..<(full.count - 50)]))
        #expect(drain(&d).isEmpty)
        d.push(Array(full[(full.count - 50)...]))
        #expect(drain(&d).count == 1)
    }

    @Test func garbageBeforeTheStreamIsDiscarded() {
        var b = OggStreamBuilder()
        var d = OggDemuxer()
        d.push(payload(99, 5000))
        d.push(b.page([payload(1, 60)], granule: 960, bos: true))
        let out = drain(&d)
        #expect(out.count == 1)
        #expect(d.resyncDiscardedBytes >= 5000)
    }

    @Test func pureGarbageDoesNotGrowTheBufferWithoutBound() {
        var d = OggDemuxer()
        for _ in 0..<40 { d.push(payload(3, 100_000)) }   // 4 MB of noise
        #expect(drain(&d).isEmpty)
        #expect(d.resyncDiscardedBytes > 3_000_000)
    }
}

// MARK: - Chained streams

@Suite struct OggChainingTests {
    /// An encoder may end one logical bitstream and start another at a track
    /// boundary, with a new serial. Not handling it presents as "plays the
    /// first track then stops".
    @Test func secondBitstreamIsDeliveredAndFlagged() {
        var a = OggStreamBuilder(serial: 0xAAAA_AAAA)
        var b = OggStreamBuilder(serial: 0xBBBB_BBBB)
        var stream: [UInt8] = []
        stream += a.page([opusHeadPacket()], granule: 0, bos: true)
        stream += a.page([opusTagsPacket], granule: 0)
        stream += a.page([payload(1, 50)], granule: 960, eos: true)
        stream += b.page([opusHeadPacket(channels: 1, preSkip: 156)], granule: 0, bos: true)
        stream += b.page([opusTagsPacket], granule: 0)
        stream += b.page([payload(2, 50)], granule: 960, eos: true)

        var d = OggDemuxer(); d.push(stream)
        let out = drain(&d)
        #expect(out.count == 6)
        #expect(out[0].startsStream == true)
        #expect(out[0].serial == 0xAAAA_AAAA)
        #expect(out[2].endsStream == true)
        #expect(out[3].startsStream == true)
        #expect(out[3].serial == 0xBBBB_BBBB)
        #expect(OggCodecIdentifier.identify(firstPacket: out[3].data) == .opus(
            OpusHeader(channels: 1, preSkip: 156, inputSampleRate: 48000, outputGain: 0, mappingFamily: 0)))
    }

    @Test func onlyTheFirstPacketOfABitstreamIsFlaggedAsStarting() {
        var b = OggStreamBuilder()
        var d = OggDemuxer()
        d.push(b.page([opusHeadPacket(), payload(1, 10)], granule: 0, bos: true))
        let out = drain(&d)
        #expect(out.count == 2)
        #expect(out[0].startsStream == true)
        #expect(out[1].startsStream == false)
    }

    /// Packets from an unrelated multiplexed stream must stay separable rather
    /// than being spliced into one packet sequence.
    @Test func interleavedSerialsDoNotCorruptEachOther() {
        var a = OggStreamBuilder(serial: 1)
        var b = OggStreamBuilder(serial: 2)
        var stream: [UInt8] = []
        // 510 = 255 * 2: serial 1's packet is left open across serial 2's page.
        stream += a.rawPage(segments: [255, 255], body: payload(1, 510), granule: -1, bos: true)
        stream += b.page([payload(9, 40)], granule: 960, bos: true)
        stream += a.rawPage(segments: [10], body: payload(2, 10), granule: 960, continued: true)

        var d = OggDemuxer(); d.push(stream)
        let out = drain(&d)
        #expect(out.count == 2)
        #expect(out[0].serial == 2)
        #expect(out[0].data == payload(9, 40))
        #expect(out[1].serial == 1)
        #expect(out[1].data == payload(1, 510) + payload(2, 10))
    }
}

// MARK: - Codec identification

@Suite struct OggCodecIdentificationTests {
    @Test func opusHeaderFields() {
        let h = OpusHeader.parse(opusHeadPacket(channels: 2, preSkip: 312, rate: 48000))
        #expect(h?.channels == 2)
        #expect(h?.preSkip == 312)
        #expect(h?.inputSampleRate == 48000)
        #expect(h?.mappingFamily == 0)
    }

    @Test func opusPreSkipIsLittleEndianAndCanExceedAByte() {
        // 1000 is Apple's encoder lookahead; a big-endian read would give 59392.
        #expect(OpusHeader.parse(opusHeadPacket(preSkip: 1000))?.preSkip == 1000)
        #expect(OpusHeader.parse(opusHeadPacket(preSkip: 65535))?.preSkip == 65535)
    }

    @Test func identifiesEachCodec() {
        #expect(OggCodecIdentifier.identify(firstPacket: opusHeadPacket()).displayName == "Opus")
        #expect(OggCodecIdentifier.identify(firstPacket: [0x7F] + Array("FLAC".utf8) + [1, 0]) == .flac)
        #expect(OggCodecIdentifier.identify(firstPacket: [0x01] + Array("vorbis".utf8)) == .vorbis)
        #expect(OggCodecIdentifier.identify(firstPacket: payload(1, 30)) == .unknown)
    }

    @Test func onlyOpusAndFLACArePlayable() {
        // iOS has no Vorbis decoder at all: 'vorb' is absent from
        // kAudioFormatProperty_DecodeFormatIDs and "Vorbis" appears nowhere in
        // the SDK headers. It is identified so the user gets a reason, never
        // decoded.
        #expect(OggCodecIdentifier.identify(firstPacket: opusHeadPacket()).isPlayable)
        #expect(OggCodec.flac.isPlayable)
        #expect(!OggCodec.vorbis.isPlayable)
        #expect(!OggCodec.unknown.isPlayable)
    }

    @Test func truncatedOrWrongHeadersAreNotOpus() {
        #expect(OpusHeader.parse(Array("OpusHead".utf8)) == nil)
        #expect(OpusHeader.parse(Array("OpusTags".utf8) + payload(1, 20)) == nil)
        #expect(OpusHeader.parse([]) == nil)
    }

    @Test func commentHeadersAreRecognised() {
        #expect(OggCodecIdentifier.isCommentHeader(opusTagsPacket, codec: .opus(
            OpusHeader(channels: 2, preSkip: 312, inputSampleRate: 48000, outputGain: 0, mappingFamily: 0))))
        #expect(!OggCodecIdentifier.isCommentHeader(payload(1, 40), codec: .opus(
            OpusHeader(channels: 2, preSkip: 312, inputSampleRate: 48000, outputGain: 0, mappingFamily: 0))))
        #expect(OggCodecIdentifier.isCommentHeader([0x03] + Array("vorbis".utf8), codec: .vorbis))
    }
}
