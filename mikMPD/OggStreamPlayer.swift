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
    private var converter: AudioConverterRef?
    private var outputFormat: AVAudioFormat?
    private var codec: OggCodec = .unknown
    private var currentSerial: UInt32?
    private var preSkipRemaining = 0
    private var started = false
    private var scheduledBuffers = 0
    private var state: OggStreamState = .idle

    /// Frames buffered before playback starts. MPD's httpd is a live stream with
    /// no duration to lean on, so this is the only thing standing between a LAN
    /// hiccup and a dropout.
    private static let startThresholdFrames = 48000 / 2      // 0.5 s
    private static let maxScheduledBuffers = 24

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
            preSkipRemaining = 0
            started = false
            scheduledBuffers = 0
            setState(.buffering)

            let config = URLSessionConfiguration.default
            config.requestCacheePolicyWorkaround()
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
        if let c = converter { AudioConverterDispose(c); converter = nil }
        outputFormat = nil
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
            guard packet.serial == currentSerial else { continue }   // other multiplexed stream
            if OggCodecIdentifier.isCommentHeader(packet.data, codec: codec) { continue }
            if case .flac = codec, packet.data.first.map({ $0 & 0x7F }) != nil, converter == nil {
                // FLAC's remaining metadata blocks precede audio; skip until set up.
                continue
            }
            guard converter != nil else { continue }
            decode(packet.data)
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
        if let c = converter { AudioConverterDispose(c); converter = nil }

        switch identified {
        case .opus(let head):
            preSkipRemaining = head.preSkip
            configureConverter(formatID: kAudioFormatOpus,
                               channels: head.channels,
                               framesPerPacket: 960)
        case .flac:
            // STREAMINFO carries rate and channels; until it is parsed, defer.
            preSkipRemaining = 0
            configureConverter(formatID: kAudioFormatFLAC, channels: 2, framesPerPacket: 0)
        default:
            break
        }
    }

    /// Opus always decodes at 48 kHz regardless of the header's input rate.
    private func configureConverter(formatID: AudioFormatID, channels: Int, framesPerPacket: UInt32) {
        let rate: Double = 48000
        var src = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: formatID, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        guard let out = AVAudioFormat(standardFormatWithSampleRate: rate,
                                      channels: AVAudioChannelCount(channels)) else {
            fail("Unsupported channel layout"); return
        }
        var dst = out.streamDescription.pointee
        var c: AudioConverterRef?
        // No magic cookie: Apple's Opus cookie has no published layout, and a
        // fully specified ASBD alone decodes byte-identically.
        guard AudioConverterNew(&src, &dst, &c) == noErr, let c else {
            fail("Could not start the \(codec.displayName) decoder"); return
        }
        converter = c
        outputFormat = out
        startEngineIfNeeded(format: out)
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

    // MARK: - Decoding

    /// Holds the one packet the converter's input callback will hand back.
    private final class PacketFeed {
        var bytes: [UInt8] = []
        var desc = AudioStreamPacketDescription()
        var consumed = true
    }
    private let feed = PacketFeed()

    private func decode(_ packet: [UInt8]) {
        guard let converter, let format = outputFormat else { return }
        feed.bytes = packet
        feed.consumed = false

        // Opus tops out at 120 ms per packet; 5760 frames at 48 kHz covers it.
        let capacity: AVAudioFrameCount = 5760
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }

        var frames = capacity
        var abl = buffer.mutableAudioBufferList.pointee
        var status: OSStatus = noErr
        withUnsafeMutablePointer(to: &abl) { ablPtr in
            status = AudioConverterFillComplexBuffer(
                converter, Self.inputProc,
                Unmanaged.passUnretained(feed).toOpaque(),
                &frames, ablPtr, nil)
        }
        guard status == noErr || status == 1, frames > 0 else { return }
        buffer.frameLength = frames
        // The buffer list the converter filled is a copy; mirror the count back.
        buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize =
            frames * format.streamDescription.pointee.mBytesPerFrame

        schedule(trimmingPreSkip: buffer, format: format)
    }

    /// CoreAudio calls this on its own thread — `@Sendable` is not optional here.
    /// With default MainActor isolation a plain closure is inferred `@MainActor`
    /// and traps at runtime when the framework invokes it off-main.
    private static let inputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, outDataPacketDescription, userData in
        guard let userData else { ioNumberDataPackets.pointee = 0; return noErr }
        let feed = Unmanaged<PacketFeed>.fromOpaque(userData).takeUnretainedValue()
        if feed.consumed || feed.bytes.isEmpty {
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        feed.consumed = true
        feed.desc = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(feed.bytes.count))
        ioNumberDataPackets.pointee = 1
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = 0
        ioData.pointee.mBuffers.mDataByteSize = UInt32(feed.bytes.count)
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: feed.bytes)
        outDataPacketDescription?.pointee = withUnsafeMutablePointer(to: &feed.desc) { $0 }
        return noErr
    }

    /// RFC 7845 §4.2: the first `preSkip` samples are encoder priming and must be
    /// dropped, or every stream opens with a click.
    private func schedule(trimmingPreSkip buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        var toPlay = buffer
        if preSkipRemaining > 0 {
            let drop = min(preSkipRemaining, Int(buffer.frameLength))
            preSkipRemaining -= drop
            let remaining = Int(buffer.frameLength) - drop
            guard remaining > 0 else { return }
            guard let trimmed = AVAudioPCMBuffer(pcmFormat: format,
                                                 frameCapacity: AVAudioFrameCount(remaining)),
                  let src = buffer.floatChannelData, let dst = trimmed.floatChannelData
            else { return }
            for ch in 0..<Int(format.channelCount) {
                dst[ch].update(from: src[ch] + drop, count: remaining)
            }
            trimmed.frameLength = AVAudioFrameCount(remaining)
            toPlay = trimmed
        }

        guard started else { return }
        scheduledBuffers += 1
        node.scheduleBuffer(toPlay) { [weak self] in
            guard let self else { return }
            self.queue.async { self.scheduledBuffers -= 1 }
        }

        if node.isPlaying == false,
           scheduledBuffers * Int(toPlay.frameLength) >= Self.startThresholdFrames {
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

private extension URLSessionConfiguration {
    /// A live stream must never be served from cache.
    func requestCacheePolicyWorkaround() {
        requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        urlCache = nil
        timeoutIntervalForRequest = 30
    }
}
