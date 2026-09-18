// OggDemuxer.swift
// Ogg bitstream parsing (RFC 3533), incremental and pure.
//
// Why this exists rather than AudioFileStream: iOS *does* parse Ogg — verified,
// including with no type hint — but AudioFile.h declares no Ogg type constant,
// so it is behaviour Apple has never published and can withdraw. The codec side
// stays Apple's (kAudioFormatOpus/kAudioFormatFLAC are documented); only the
// container is ours. See docs/plans/v1.7/02-opus-phone-streaming.md.
//
// No Foundation networking, no AudioToolbox: bytes in, packets out, so the whole
// thing is unit-testable without a server or a device.
import Foundation

/// Codecs identifiable from the first packet of a logical bitstream.
nonisolated enum OggCodec: Equatable {
    case opus(OpusHeader)
    case flac(FLACStreamInfo)
    case vorbis          // identified so the user gets a reason, never decoded
    case unknown

    /// Name for user-facing messages.
    var displayName: String {
        switch self {
        case .opus:    "Opus"
        case .flac:    "FLAC"
        case .vorbis:  "Vorbis"
        case .unknown: "an unrecognised codec"
        }
    }

    /// Whether iOS can decode this. Vorbis is deliberately absent: no system
    /// decoder exists and vendoring libvorbis is out of scope.
    var isPlayable: Bool {
        switch self {
        case .opus, .flac: true
        case .vorbis, .unknown: false
        }
    }
}

/// The Opus identification header (RFC 7845 §5.1).
nonisolated struct OpusHeader: Equatable {
    var channels: Int
    /// Samples to discard from the front of the decoded stream, at 48 kHz.
    /// Not honouring it puts a click at the start of every stream.
    var preSkip: Int
    /// The *original* rate before encoding. Opus always decodes at 48 kHz;
    /// this field is informational and must not be used as the output rate.
    var inputSampleRate: Int
    var outputGain: Int
    var mappingFamily: Int

    static func parse(_ p: [UInt8]) -> OpusHeader? {
        guard p.count >= 19, Array(p[0..<8]) == Array("OpusHead".utf8) else { return nil }
        // p[8] is the version; the spec says accept anything with major version 0.
        guard p[8] & 0xF0 == 0 else { return nil }
        return OpusHeader(channels: Int(p[9]),
                          preSkip: Int(p[10]) | Int(p[11]) << 8,
                          inputSampleRate: Int(p[12]) | Int(p[13]) << 8 | Int(p[14]) << 16 | Int(p[15]) << 24,
                          outputGain: Int(Int16(bitPattern: UInt16(p[16]) | UInt16(p[17]) << 8)),
                          mappingFamily: Int(p[18]))
    }
}

/// The FLAC STREAMINFO block, from the first packet of an Ogg FLAC stream.
///
/// Needed to decode at all, not just to decode right. `AudioConverterNew`
/// refuses a FLAC format whose frames-per-packet is 0 — v1.7 passed exactly
/// that, so Ogg FLAC never played — and a frames-per-packet smaller than the
/// stream's block size decodes nothing (both verified with macOS's decoder).
/// The sample rate matters as much: MPD's FLAC encoder sends the *source file's*
/// rate, so a CD rip arrives at 44.1 kHz and decoding it as 48 kHz plays it ~9 %
/// fast; and since the rate follows the file, it can change at a track boundary.
nonisolated struct FLACStreamInfo: Equatable {
    var sampleRate: Int
    var channels: Int
    var bitsPerSample: Int
    var minBlockSize: Int
    var maxBlockSize: Int

    /// Ogg FLAC mapping: `0x7F "FLAC"`, version (2 bytes), header count
    /// (2 bytes), `"fLaC"`, then a metadata block header (type 0 = STREAMINFO,
    /// 3-byte length 34) and the 34-byte STREAMINFO itself, all big-endian.
    static func parse(oggFirstPacket p: [UInt8]) -> FLACStreamInfo? {
        guard p.count >= 51,
              p[0] == 0x7F, Array(p[1..<5]) == Array("FLAC".utf8),
              Array(p[9..<13]) == Array("fLaC".utf8),
              p[13] & 0x7F == 0 else { return nil }
        let si = Array(p[17..<51])
        let minBS = Int(si[0]) << 8 | Int(si[1])
        let maxBS = Int(si[2]) << 8 | Int(si[3])
        // 20 bits of rate, 3 of channels−1, 5 of bits-per-sample−1.
        let rate = Int(si[10]) << 12 | Int(si[11]) << 4 | Int(si[12]) >> 4
        let channels = Int((si[12] >> 1) & 0x07) + 1
        let bits = (Int(si[12] & 0x01) << 4 | Int(si[13]) >> 4) + 1
        guard rate > 0, maxBS >= 16, minBS <= maxBS else { return nil }
        return FLACStreamInfo(sampleRate: rate, channels: channels, bitsPerSample: bits,
                              minBlockSize: minBS, maxBlockSize: maxBS)
    }
}

/// One complete packet, reassembled across as many pages as it spanned.
nonisolated struct OggPacket: Equatable {
    var data: [UInt8]
    /// Serial of the logical bitstream it belongs to.
    var serial: UInt32
    /// Granule position of the page the packet *finished* on, or -1 if that page
    /// carried no packet end. For Opus this counts 48 kHz samples.
    var granulePosition: Int64
    /// True when this packet began a new logical bitstream (the BOS page's
    /// first packet) — the signal to re-read headers on a chained stream.
    var startsStream: Bool
    /// True when this packet came from a page flagged end-of-stream.
    var endsStream: Bool
}

/// Incremental Ogg parser. Feed it arbitrary byte chunks; pull whole packets.
///
/// Deliberately tolerant, because it is fed a *live* stream: it joins mid-page,
/// resyncs after loss, and validates every page's CRC so a capture pattern
/// occurring inside packet payload cannot desync it.
nonisolated struct OggDemuxer {

    /// Guard against a malformed stream growing the buffer without bound. A page
    /// is at most 65307 bytes, so anything beyond a few pages means we are not
    /// looking at Ogg (or lost the plot) and should discard rather than grow.
    static let maxBufferBytes = 1 << 20   // 1 MiB

    private var buffer: [UInt8] = []
    /// Partially assembled packet per serial, for packets spanning pages.
    private var partials: [UInt32: [UInt8]] = [:]
    /// Packets parsed out of pages but not yet handed to the caller.
    private var ready: [OggPacket] = []
    /// Serials whose BOS page we have seen, so `startsStream` is only set once.
    private var seenBOS: Set<UInt32> = []

    /// Bytes discarded while resyncing. Non-zero after a real stream disruption;
    /// useful in diagnostics, never used for control flow.
    private(set) var resyncDiscardedBytes = 0

    init() {}

    // MARK: - Input

    mutating func push(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
        if buffer.count > Self.maxBufferBytes {
            // Keep the tail: a page boundary is far likelier to be near the end
            // than in the megabyte of garbage we are dropping.
            let drop = buffer.count - Self.maxBufferBytes
            buffer.removeFirst(drop)
            resyncDiscardedBytes += drop
        }
        parseAvailablePages()
    }

    mutating func push(_ data: Data) { push([UInt8](data)) }

    /// Next complete packet, or nil when more bytes are needed.
    mutating func nextPacket() -> OggPacket? {
        ready.isEmpty ? nil : ready.removeFirst()
    }

    // MARK: - Page parsing

    private static let capturePattern: [UInt8] = Array("OggS".utf8)
    private static let headerFixedSize = 27

    private mutating func parseAvailablePages() {
        var cursor = 0
        while true {
            guard let start = Self.findCapture(in: buffer, from: cursor) else {
                // No capture pattern left. Keep only the last 3 bytes, which may
                // be the head of a pattern split across chunk boundaries.
                let keep = min(buffer.count, Self.capturePattern.count - 1)
                let drop = buffer.count - keep
                if drop > 0 {
                    resyncDiscardedBytes += max(0, drop - cursor)
                    buffer.removeFirst(drop)
                }
                return
            }
            if start > cursor { resyncDiscardedBytes += start - cursor }

            guard buffer.count - start >= Self.headerFixedSize else {
                // Header incomplete — wait for more bytes.
                buffer.removeFirst(start); return
            }
            let segCount = Int(buffer[start + 26])
            let headerSize = Self.headerFixedSize + segCount
            guard buffer.count - start >= headerSize else { buffer.removeFirst(start); return }

            let segTable = Array(buffer[(start + Self.headerFixedSize)..<(start + headerSize)])
            let bodySize = segTable.reduce(0) { $0 + Int($1) }
            let pageSize = headerSize + bodySize
            guard buffer.count - start >= pageSize else { buffer.removeFirst(start); return }

            let page = Array(buffer[start..<(start + pageSize)])
            if Self.version(page) == 0, Self.crcIsValid(page) {
                emitPackets(from: page, segmentTable: segTable, headerSize: headerSize)
                buffer.removeFirst(start + pageSize)
                cursor = 0
            } else {
                // Not a real page: a capture pattern inside payload, or a corrupt
                // one. Skip these 4 bytes and keep scanning — this is exactly
                // what the CRC check is here to make safe.
                cursor = start + 1
            }
        }
    }

    private static func findCapture(in bytes: [UInt8], from index: Int) -> Int? {
        guard bytes.count >= capturePattern.count else { return nil }
        var i = max(0, index)
        let last = bytes.count - capturePattern.count
        while i <= last {
            if bytes[i] == 0x4F, bytes[i+1] == 0x67, bytes[i+2] == 0x67, bytes[i+3] == 0x53 { return i }
            i += 1
        }
        return nil
    }

    private static func version(_ page: [UInt8]) -> UInt8 { page[4] }

    private static func headerType(_ page: [UInt8]) -> UInt8 { page[5] }

    private static func granule(_ page: [UInt8]) -> Int64 {
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = v << 8 | UInt64(page[6 + i]) }
        return Int64(bitPattern: v)
    }

    private static func serial(_ page: [UInt8]) -> UInt32 {
        UInt32(page[14]) | UInt32(page[15]) << 8 | UInt32(page[16]) << 16 | UInt32(page[17]) << 24
    }

    private mutating func emitPackets(from page: [UInt8], segmentTable: [UInt8], headerSize: Int) {
        let flags = Self.headerType(page)
        let isContinued = flags & 0x01 != 0
        let isBOS       = flags & 0x02 != 0
        let isEOS       = flags & 0x04 != 0
        let ser         = Self.serial(page)
        let gran        = Self.granule(page)

        if isBOS {
            // A new logical bitstream: anything half-assembled for this serial
            // belongs to the previous one and is void.
            partials[ser] = nil
        }

        var startsStream = isBOS && !seenBOS.contains(ser)

        // A page that does not continue a previous packet invalidates any
        // partial we were holding — the continuation was lost.
        if !isContinued { partials[ser] = nil }

        var offset = headerSize
        var accumulated = partials[ser] ?? []
        for lacing in segmentTable {
            let n = Int(lacing)
            accumulated.append(contentsOf: page[offset..<(offset + n)])
            offset += n
            if n < 255 {
                // Lacing value < 255 terminates a packet.
                ready.append(OggPacket(data: accumulated, serial: ser,
                                       granulePosition: gran,
                                       startsStream: startsStream, endsStream: isEOS))
                if startsStream { seenBOS.insert(ser); startsStream = false }
                accumulated = []
            }
        }
        partials[ser] = accumulated.isEmpty ? nil : accumulated
    }

    // MARK: - CRC

    /// Ogg's CRC-32: polynomial 0x04c11db7, init 0, **no** reflection and no
    /// final xor — not the common zlib variant. Getting this wrong makes every
    /// page look corrupt, which presents as "no audio" rather than as a checksum
    /// bug, so it is table-tested directly.
    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var r = UInt32(i) << 24
            for _ in 0..<8 { r = r & 0x8000_0000 != 0 ? (r << 1) ^ 0x04c1_1db7 : r << 1 }
            return r
        }
    }()

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0
        for b in bytes { crc = (crc << 8) ^ crcTable[Int(((crc >> 24) ^ UInt32(b)) & 0xFF)] }
        return crc
    }

    /// CRC over the page with the checksum field itself zeroed.
    static func crcIsValid(_ page: [UInt8]) -> Bool {
        guard page.count >= headerFixedSize else { return false }
        let stated = UInt32(page[22]) | UInt32(page[23]) << 8 | UInt32(page[24]) << 16 | UInt32(page[25]) << 24
        var copy = page
        copy[22] = 0; copy[23] = 0; copy[24] = 0; copy[25] = 0
        return crc32(copy) == stated
    }
}

// MARK: - Codec identification

nonisolated enum OggCodecIdentifier {
    /// Identify a logical bitstream from its first packet.
    static func identify(firstPacket p: [UInt8]) -> OggCodec {
        if let head = OpusHeader.parse(p) { return .opus(head) }
        if p.count >= 5, p[0] == 0x7F, Array(p[1..<5]) == Array("FLAC".utf8) {
            // Without a readable STREAMINFO there is nothing to configure a
            // decoder with, so it is as good as unrecognised.
            return FLACStreamInfo.parse(oggFirstPacket: p).map(OggCodec.flac) ?? .unknown
        }
        if p.count >= 7, p[0] == 0x01, Array(p[1..<7]) == Array("vorbis".utf8) { return .vorbis }
        return .unknown
    }

    /// Whether a packet is a comment/metadata header to be skipped rather than
    /// fed to the decoder.
    static func isCommentHeader(_ p: [UInt8], codec: OggCodec) -> Bool {
        switch codec {
        case .opus:   p.count >= 8 && Array(p[0..<8]) == Array("OpusTags".utf8)
        case .vorbis: p.count >= 7 && p[0] == 0x03 && Array(p[1..<7]) == Array("vorbis".utf8)
        // Every FLAC metadata block (VORBIS_COMMENT, PADDING, PICTURE, …) is a
        // header; only audio frames, which open with the 0xFF sync byte, decode.
        case .flac:   p.first != 0xFF
        case .unknown: false
        }
    }
}
