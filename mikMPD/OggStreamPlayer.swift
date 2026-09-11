// OggStreamPlayer.swift
// Plays an endless Ogg stream from MPD's httpd output: URLSession → OggDemuxer
// → AudioConverter → AVAudioEngine.
//
// AVPlayer keeps the mp3 path; this exists only for what AVPlayer cannot open.
// Adding a path is a smaller risk than replacing a working one — AVPlayer does
// buffering, stall recovery, interruptions and route changes for free, and all
// of that becomes ours here.
import Foundation
import AVFoundation
import AudioToolbox

/// What the player is doing, for `handleEnteringBackground` and the UI.
///
/// `isRendering` exists for the same reason `AVPlayer.timeControlStatus` is
/// consulted there: a stream that failed or was stopped by the server must not
/// leave the app believing it is streaming, which held the audio session open so
/// other apps were never told they could resume.
nonisolated enum OggStreamState: Equatable {
    case idle
    case buffering
    case playing
    case failed(String)

    var isRendering: Bool { self == .playing || self == .buffering }

    /// Whether the store should stop phone streaming on reaching this state.
    /// `.idle` is included because a server closing the connection — MPD
    /// restarting, the httpd output being disabled — arrives as `.idle`, not
    /// `.failed`.
    var endsPhoneStream: Bool {
        switch self {
        case .idle, .failed: true
        case .buffering, .playing: false
        }
    }
}

/// Codecs this app can play over http, for user-facing copy. The list is a fact
/// about the app, not a setting — there is nothing to configure and nothing to
/// keep in sync with mpd.conf.
nonisolated enum HTTPStreamCodecs {
    static let supported = "MP3, Opus and FLAC"

    /// Message for a stream carrying something we cannot decode.
    static func unsupportedMessage(for codec: OggCodec) -> String {
        "This stream is Ogg \(codec.displayName), which iOS cannot decode. "
        + "mikMPD can play \(supported) — change the httpd output's encoder to \"opus\"."
    }
}

/// What phone streaming does when the audio route changes.
nonisolated enum PhoneStreamRouteAction: Equatable {
    case stop, restartOggStream, ignore
}

/// Headphones unplugged — or a Bluetooth device gone — must stop the stream.
/// iOS convention is to stop rather than blast the speaker, and AVAudioEngine
/// stops itself on the route change anyway, which used to leave "Streaming to
/// phone" on screen with no sound anywhere. A device *arriving* also stops the
/// engine, so the Ogg stream restarts onto the new route; AVPlayer follows route
/// changes by itself. Everything else is ignored — including the category change
/// this app makes when it starts streaming, which would otherwise restart the
/// stream in a loop.
nonisolated func phoneStreamRouteAction(for reason: AVAudioSession.RouteChangeReason,
                                        oggPlayerActive: Bool) -> PhoneStreamRouteAction {
    switch reason {
    case .oldDeviceUnavailable: .stop
    case .newDeviceAvailable:   oggPlayerActive ? .restartOggStream : .ignore
    default:                    .ignore
    }
}

/// Which player should handle a stream, decided per stream start from the
/// response's Content-Type. Nothing about it is persisted: changing the MPD
/// encoder needs no action in the app.
nonisolated enum StreamPlayerKind: Equatable {
    case system      // AVPlayer — mp3, AAC, wav
    case ogg         // this file

    static func forContentType(_ contentType: String?) -> StreamPlayerKind {
        guard let t = contentType?.lowercased() else { return .system }
        // Strip any parameters: "audio/ogg; codecs=opus".
        let base = t.split(separator: ";").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? t
        switch base {
        case "audio/ogg", "application/ogg", "audio/opus", "audio/flac", "audio/x-flac":
            return .ogg
        default:
            // mp3, wav, anything unrecognised: AVPlayer is the better guess and
            // knows more container formats than we do.
            return .system
        }
    }
}

/// Streams and decodes Ogg audio. Not an `ObservableObject`: it is owned by
/// `MPDStore`, which republishes what the UI needs.
///
/// `nonisolated` on purpose. With default MainActor isolation this type would be
/// main-actor bound, but nothing in it runs there: URLSession delivers on its own
/// queue, CoreAudio calls the input proc on a render thread, and all internal
/// state is confined to `queue` — the same invariant `MPDSocket` documents for
/// `Q`. Only `onStateChange` hops to main.
nonisolated final class OggStreamPlayer: NSObject, @unchecked Sendable {

    /// Called on the main actor whenever the state changes.
    private let onStateChange: @MainActor (OggStreamState) -> Void

    // Everything below is touched only from `queue` (or, for the engine, from
    // `queue` while the render thread reads it) — the same invariant MPDSocket
    // documents for `Q`.
    private let queue = DispatchQueue(label: "mikmpd.oggstream", qos: .userInitiated)

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var demuxer = OggDemuxer()

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var decoder: OggPacketDecoder?
    private var codec: OggCodec = .unknown
    private var currentSerial: UInt32?
    private var started = false
    private var scheduledBuffers = 0
    private var state: OggStreamState = .idle

    /// Frames buffered before playback starts. MPD's httpd is a live stream with
    /// no duration to lean on, so this is the only thing standing between a LAN
    /// hiccup and a dropout.
    private static let startThresholdFrames = 48000 / 2      // 0.5 s

    init(onStateChange: @escaping @MainActor (OggStreamState) -> Void) {
        self.onStateChange = onStateChange
        super.init()
    }

    // MARK: - Lifecycle

    func start(url: URL) {
        queue.async { [self] in
            teardownLocked()
            demuxer = OggDemuxer()
            codec = .unknown
            currentSerial = nil
            started = false
            scheduledBuffers = 0
            setState(.buffering)

            let config = URLSessionConfiguration.default
            // A live stream must never be served from cache.
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.urlCache = nil
            config.timeoutIntervalForRequest = 30
            let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            session = s
            var req = URLRequest(url: url)
            req.setValue("1", forHTTPHeaderField: "Icy-MetaData")   // harmless if unsupported
            let t = s.dataTask(with: req)
            task = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            teardownLocked()
            setState(.idle)
        }
    }

    private func teardownLocked() {
        task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
        if started { node.stop(); engine.stop(); started = false }
        decoder?.close(); decoder = nil
    }

    private func setState(_ s: OggStreamState) {
        guard s != state else { return }
        state = s
        let cb = onStateChange
        DispatchQueue.main.async { cb(s) }
    }

    private func fail(_ message: String) {
        teardownLocked()
        setState(.failed(message))
    }

    // MARK: - Packet handling (on `queue`)

    private func consume(_ bytes: [UInt8]) {
        demuxer.push(bytes)
        while let packet = demuxer.nextPacket() {
            if packet.startsStream {
                // A new logical bitstream: a chained stream at a track boundary.
                // Reconfiguring here is what stops "plays the first track and
                // then goes quiet".
                beginBitstream(packet)
                continue
            }
            // Another multiplexed stream, or no decoder for this one.
            guard packet.serial == currentSerial, let decoder else { continue }
            if OggCodecIdentifier.isCommentHeader(packet.data, codec: codec) { continue }
            if let buffer = decoder.decode(packet.data) { schedule(buffer) }
        }
    }

    private func beginBitstream(_ packet: OggPacket) {
        let identified = OggCodecIdentifier.identify(firstPacket: packet.data)
        guard identified.isPlayable else {
            fail(HTTPStreamCodecs.unsupportedMessage(for: identified))
            return
        }
        codec = identified
        currentSerial = packet.serial
        decoder?.close(); decoder = nil
        guard let d = OggPacketDecoder(codec: identified) else {
            fail("Could not start the \(identified.displayName) decoder")
            return
        }
        decoder = d
        startEngineIfNeeded(format: d.format)
    }

    private func startEngineIfNeeded(format: AVAudioFormat) {
        if started { node.stop(); engine.stop(); engine.detach(node); started = false }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch {
            fail("Audio engine: \(error.localizedDescription)"); return
        }
        started = true
        scheduledBuffers = 0
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        guard started else { return }
        scheduledBuffers += 1
        node.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.queue.async { self.scheduledBuffers -= 1 }
        }
        if node.isPlaying == false,
           scheduledBuffers * Int(buffer.frameLength) >= Self.startThresholdFrames {
            node.play()
            setState(.playing)
        }
    }
}

// MARK: - URLSession

nonisolated extension OggStreamPlayer: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let bytes = [UInt8](data)
        queue.async { [weak self] in self?.consume(bytes) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async { [weak self] in
            guard let self else { return }
            // A cancel is our own teardown, not a failure worth reporting.
            if let error, (error as NSError).code != NSURLErrorCancelled {
                self.fail(error.localizedDescription)
            } else if error == nil {
                // The server closed the stream.
                self.teardownLocked()
                self.setState(.idle)
            }
        }
    }
}

// MARK: - Decoding

/// Decodes one Ogg logical bitstream's packets to PCM with the system decoder.
///
/// Separate from the player so it can be tested on real Opus packets with no
/// network, engine or device — the only way to see audio come out of it, since
/// a simulator cannot be listened to.
nonisolated final class OggPacketDecoder {
    /// Non-interleaved Float32 at 48 kHz: the engine's standard format.
    let format: AVAudioFormat
    private let converter: AudioConverterRef
    private let channels: UInt32
    private var preSkipRemaining: Int
    private var closed = false

    /// Opus packets are at most 120 ms, which is 5760 frames at 48 kHz.
    static let maxFramesPerPacket: AVAudioFrameCount = 5760

    /// What the input callback returns once its single packet is spent.
    ///
    /// Not `noErr` with zero packets: that tells AudioConverter the *stream* has
    /// ended, after which later fill calls can produce nothing. A non-zero status
    /// ends only the current fill call, and `decode` accepts it as success.
    fileprivate static let packetSpent = OSStatus(bitPattern: 0x7370_6E74)   // 'spnt'

    init?(codec: OggCodec) {
        let rate: Double = 48000
        let chans: Int
        let formatID: AudioFormatID
        let framesPerPacket: UInt32
        let preSkip: Int
        switch codec {
        case .opus(let head):
            chans = head.channels; formatID = kAudioFormatOpus
            framesPerPacket = 960; preSkip = head.preSkip
        case .flac:
            // STREAMINFO is not parsed yet; this assumes 48 kHz stereo.
            chans = 2; formatID = kAudioFormatFLAC
            framesPerPacket = 0; preSkip = 0
        case .vorbis, .unknown:
            return nil
        }
        guard chans > 0,
              let out = AVAudioFormat(standardFormatWithSampleRate: rate,
                                      channels: AVAudioChannelCount(chans)) else { return nil }
        var src = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: formatID, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(chans), mBitsPerChannel: 0, mReserved: 0)
        var dst = out.streamDescription.pointee
        var c: AudioConverterRef?
        // No magic cookie: Apple's Opus cookie has no published layout, and a
        // fully specified ASBD alone decodes byte-identically.
        guard AudioConverterNew(&src, &dst, &c) == noErr, let c else { return nil }
        converter = c
        format = out
        channels = UInt32(chans)
        preSkipRemaining = preSkip
    }

    /// PCM for one packet with any remaining pre-skip removed, or nil when the
    /// packet produced nothing (a header, a malformed packet, or all pre-skip).
    func decode(_ packet: [UInt8]) -> AVAudioPCMBuffer? {
        guard !closed, !packet.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: Self.maxFramesPerPacket) else { return nil }
        // An AVAudioPCMBuffer's buffer list advertises `frameLength` bytes, and a
        // new buffer's `frameLength` is zero. Handed over as-is, the converter
        // sees output buffers with no room, writes nothing and still reports
        // success — the first version produced silence this way. Open the full
        // capacity for the fill, then shrink to what was produced.
        buffer.frameLength = buffer.frameCapacity
        var frames = Self.maxFramesPerPacket
        var status: OSStatus = noErr
        let converter = self.converter, channels = self.channels

        // Every pointer the input callback hands the converter is valid only
        // inside these scopes, and the converter reads them only during
        // FillComplexBuffer — which is why that call sits innermost. The first
        // version stored the `[UInt8]` and turned it into a pointer inside the
        // callback, which dangled the moment that conversion returned.
        packet.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var desc = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(raw.count))
            withUnsafeMutablePointer(to: &desc) { descPtr in
                let feed = PacketFeed(data: UnsafeMutableRawPointer(mutating: base),
                                      byteCount: UInt32(raw.count),
                                      channels: channels, desc: descPtr)
                // The buffer's own list, never a copy. The standard format is
                // non-interleaved, so a stereo list holds two AudioBuffers; a
                // copied `AudioBufferList` struct has room for one, and the
                // converter wrote the second channel past the end of it.
                status = withExtendedLifetime(feed) {
                    AudioConverterFillComplexBuffer(
                        converter, Self.inputProc,
                        Unmanaged.passUnretained(feed).toOpaque(),
                        &frames, buffer.mutableAudioBufferList, nil)
                }
            }
        }
        guard status == noErr || status == Self.packetSpent, frames > 0 else { return nil }
        buffer.frameLength = frames
        return trimmingPreSkip(buffer)
    }

    /// Explicit, never `deinit`: nothing in this app relies on teardown running
    /// implicitly (CLAUDE.md, "Nothing runs on termination").
    func close() {
        guard !closed else { return }
        closed = true
        AudioConverterDispose(converter)
    }

    /// RFC 7845 §4.2: the first `preSkip` samples are encoder priming and must be
    /// dropped, or every stream opens with a click.
    private func trimmingPreSkip(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard preSkipRemaining > 0 else { return buffer }
        let drop = min(preSkipRemaining, Int(buffer.frameLength))
        preSkipRemaining -= drop
        let remaining = Int(buffer.frameLength) - drop
        guard remaining > 0,
              let trimmed = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(remaining)),
              let src = buffer.floatChannelData, let dst = trimmed.floatChannelData
        else { return nil }
        for ch in 0..<Int(format.channelCount) {
            dst[ch].update(from: src[ch] + drop, count: remaining)
        }
        trimmed.frameLength = AVAudioFrameCount(remaining)
        return trimmed
    }

    /// CoreAudio calls this on its own thread, inside FillComplexBuffer, and it
    /// touches nothing but the feed.
    private static let inputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, outDataPacketDescription, userData in
        guard let userData else {
            ioNumberDataPackets.pointee = 0
            return OggPacketDecoder.packetSpent
        }
        let feed = Unmanaged<PacketFeed>.fromOpaque(userData).takeUnretainedValue()
        guard !feed.consumed else {
            ioNumberDataPackets.pointee = 0
            return OggPacketDecoder.packetSpent
        }
        feed.consumed = true
        ioNumberDataPackets.pointee = 1
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = feed.channels
        ioData.pointee.mBuffers.mDataByteSize = feed.byteCount
        ioData.pointee.mBuffers.mData = feed.data
        outDataPacketDescription?.pointee = feed.desc
        return noErr
    }
}

/// The one packet an input callback will hand over during a single fill call.
/// Holds pointers that the caller keeps valid for that call, never the array
/// itself — so nothing is converted to a pointer inside the callback.
private nonisolated final class PacketFeed {
    let data: UnsafeMutableRawPointer
    let byteCount: UInt32
    let channels: UInt32
    let desc: UnsafeMutablePointer<AudioStreamPacketDescription>
    var consumed = false

    init(data: UnsafeMutableRawPointer, byteCount: UInt32, channels: UInt32,
         desc: UnsafeMutablePointer<AudioStreamPacketDescription>) {
        self.data = data
        self.byteCount = byteCount
        self.channels = channels
        self.desc = desc
    }
}
