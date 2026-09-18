// OggStreamPlayer.swift
// Plays an endless Ogg stream from MPD's httpd output: URLSession → OggDemuxer
// → AudioConverter → AVAudioEngine.
//
// AVPlayer keeps the mp3 path; this exists only for what AVPlayer cannot open.
// Adding a path is a smaller risk than replacing a working one — AVPlayer does
// buffering, stall recovery, interruptions and route changes for free, and all
// of that is ours here. v1.7 shipped without most of it; v1.7.1 adds a jitter
// buffer, per-format (not per-track) engine setup, engine health checks and a
// bounded reconnect — see docs/plans/v1.7.1/04-ogg-streaming-review.md.
import Foundation
import AVFoundation
import AudioToolbox

/// What the player is doing, for `handleEnteringBackground` and the UI.
nonisolated enum OggStreamState: Equatable {
    case idle
    case buffering
    case playing
    /// The connection ended or failed transiently and is being retried.
    case reconnecting(attempt: Int)
    /// Deliberately silent — MPD is paused — with the connection closed so a
    /// paused phone uses no network or audio power. `start` resumes.
    case suspended
    case failed(String)

    /// The stream is live or coming back. `isStreamActuallyRendering` relies on
    /// it: a stream that died must not leave the app believing it is streaming,
    /// which held the audio session open so other apps were never told they
    /// could resume.
    var isRendering: Bool {
        switch self {
        case .playing, .buffering, .reconnecting: true
        case .idle, .suspended, .failed: false
        }
    }

    /// Whether the store should stop phone streaming on reaching this state.
    /// A server closing the connection no longer arrives here as `.idle`: it is
    /// retried (`.reconnecting`) and only becomes `.failed` once the retry
    /// budget is spent, so "Streaming to phone" is never left on over silence
    /// for longer than that. `.idle` now means an explicit `stop()`.
    var endsPhoneStream: Bool {
        switch self {
        case .idle, .failed: true
        case .buffering, .playing, .reconnecting, .suspended: false
        }
    }
}

// MARK: - Buffer policy

/// How much decoded audio to hold. v1.7 buffered 0.5 s once, at start, and never
/// again: a network hiccup after that played silence and then stuttered packet
/// by packet, since nothing ever let the buffer get ahead again. Now a dry
/// buffer pauses and refills to the start level — one clean gap, like AVPlayer.
nonisolated struct OggBufferPolicy: Equatable {
    /// Buffered before first play and after every underrun.
    let startFrames: Int
    /// At or below this while playing: underrun — pause and rebuffer.
    let lowFrames: Int
    /// Never hold more than this. A stall is followed by a burst of backlog, and
    /// without a cap the phone would lag MPD by every stall, forever.
    let maxFrames: Int

    init(sampleRate: Double, start: Double = 2.0, low: Double = 0.25, max: Double = 6.0) {
        startFrames = Int(sampleRate * start)
        lowFrames = Int(sampleRate * low)
        maxFrames = Int(sampleRate * max)
    }

    /// Whether the node should start (or resume after an underrun).
    func shouldStart(bufferedFrames: Int) -> Bool { bufferedFrames >= startFrames }
    /// Whether a playing node has run dry enough to pause and rebuffer.
    func isUnderrun(bufferedFrames: Int) -> Bool { bufferedFrames <= lowFrames }
    /// Whether an incoming buffer fits, or should be dropped to bound latency.
    func accepts(incomingFrames: Int, bufferedFrames: Int) -> Bool {
        bufferedFrames + incomingFrames <= maxFrames
    }
}

// MARK: - Reconnect policy

/// Delay before reconnect attempt `attempt` (1-based), or nil to give up.
/// Four tries over ~15 s: long enough for a Wi-Fi roam or an MPD restart,
/// short enough that a phone that has really lost the server stops trying —
/// no retry loop runs unattended in the background.
nonisolated func oggReconnectDelay(attempt: Int) -> TimeInterval? {
    switch attempt {
    case 1: 1
    case 2: 2
    case 3: 4
    case 4: 8
    default: nil
    }
}

/// Whether a failed connection is worth retrying. Network blips and timeouts
/// are; a bad URL or an HTTP error status is not — retrying cannot fix those.
nonisolated func oggStreamErrorIsTransient(_ code: URLError.Code) -> Bool {
    switch code {
    case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
         .cannotFindHost, .dnsLookupFailed, .resourceUnavailable, .internationalRoamingOff,
         .dataNotAllowed, .secureConnectionFailed, .badServerResponse:
        true
    default:
        false
    }
}

/// Whether a player that claims to be playing has actually gone silent: no
/// buffer has finished playing back for longer than `threshold`. That is what an
/// engine stopped by iOS under us looks like (an interruption, a configuration
/// change), and v1.7 never noticed — it kept "playing" silence, and the lock
/// screen kept saying so.
nonisolated func oggStreamStalled(lastPlayedBack: Date, now: Date, state: OggStreamState,
                                  threshold: TimeInterval = 3) -> Bool {
    state == .playing && now.timeIntervalSince(lastPlayedBack) > threshold
}

/// What phone streaming does when an audio-session interruption (a call, Siri,
/// an alarm, another app) begins or ends.
nonisolated enum PhoneStreamInterruptionAction: Equatable {
    /// Go quiet and let go of the stream; AVAudioEngine has already stopped.
    case suspend
    /// Rejoin the live stream — never resume a stale buffer.
    case resume
    case ignore
}

nonisolated func phoneStreamInterruptionAction(type: AVAudioSession.InterruptionType,
                                               options: AVAudioSession.InterruptionOptions)
    -> PhoneStreamInterruptionAction {
    switch type {
    case .began: .suspend
    // Without .shouldResume (a call that was answered, say) stay quiet; the
    // lock-screen play button resumes.
    case .ended: options.contains(.shouldResume) ? .resume : .ignore
    @unknown default: .ignore
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
/// queue, CoreAudio calls the input proc and buffer completions on render
/// threads, and all internal state is confined to `queue` — the same invariant
/// `MPDSocket` documents for `Q`. Only `onStateChange` hops to main.
nonisolated final class OggStreamPlayer: NSObject, @unchecked Sendable {

    /// Called on the main actor whenever the state changes.
    private let onStateChange: @MainActor (OggStreamState) -> Void

    // Everything below is touched only from `queue`.
    private let queue = DispatchQueue(label: "mikmpd.oggstream", qos: .userInitiated)

    private var url: URL?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var demuxer = OggDemuxer()
    private var reconnectAttempt = 0

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var engineFormat: AVAudioFormat?
    private var configObserver: NSObjectProtocol?
    private var decoder: OggPacketDecoder?
    private var codec: OggCodec = .unknown
    private var currentSerial: UInt32?
    private var policy = OggBufferPolicy(sampleRate: 48000)
    private var state: OggStreamState = .idle

    /// Frames scheduled on the node and not yet played back.
    private var bufferedFrames = 0
    /// Bumped whenever scheduled audio is discarded (stop, engine rebuild), so
    /// completions of the discarded buffers — which `node.stop()` fires — cannot
    /// decrement the new count. v1.7 reset its counter and then let the old
    /// completions drive it negative, at every track change.
    private var bufferGeneration = 0
    private var lastPlayedBack = Date.distantPast

    /// Decoded audio collected into ~100 ms buffers before scheduling. One
    /// `scheduleBuffer` per 20 ms Opus packet was 50 wakes a second on two
    /// threads; this makes it 10.
    private var pending: AVAudioPCMBuffer?
    private var coalesceFrames: AVAudioFrameCount = 4800

    /// Counters for the live test, which checks that a track change begins a
    /// new bitstream without reconfiguring the engine.
    private var bitstreamsBegun = 0
    private var engineConfigurations = 0

    /// Snapshot of the counters above; test and diagnostics use only.
    func counters() -> (bitstreams: Int, engineConfigurations: Int) {
        queue.sync { (bitstreamsBegun, engineConfigurations) }
    }

    /// `muted` exists for the live test, which runs the whole pipeline against
    /// the real server without playing it through the Mac's speakers.
    init(muted: Bool = false, onStateChange: @escaping @MainActor (OggStreamState) -> Void) {
        self.onStateChange = onStateChange
        super.init()
        if muted { engine.mainMixerNode.outputVolume = 0 }
    }

    // MARK: - Lifecycle

    /// Start (or restart) at the live edge of `url`. Also how `suspend` resumes.
    func start(url: URL) {
        queue.async { [self] in
            teardownLocked()
            self.url = url
            reconnectAttempt = 0
            observeEngineConfiguration()
            setState(.buffering)
            connectLocked()
        }
    }

    /// Stop for good; `.idle` follows.
    func stop() {
        queue.async { [self] in
            teardownLocked()
            url = nil
            setState(.idle)
        }
    }

    /// Go quiet and let go of the connection — MPD is paused, or an interruption
    /// began. The engine stops too, so a suspended player costs nothing; `start`
    /// rejoins the live stream.
    func suspend() {
        queue.async { [self] in
            guard state != .idle, state != .suspended else { return }
            teardownLocked()
            setState(.suspended)
        }
    }

    private func connectLocked() {
        guard let url else { return }
        task?.cancel(); task = nil
        demuxer = OggDemuxer()
        codec = .unknown
        currentSerial = nil
        if session == nil {
            let config = URLSessionConfiguration.default
            // A live stream must never be served from cache.
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.urlCache = nil
            // Idle timeout. MPD's httpd output keeps sending (encoded silence
            // while paused), so ten seconds without a byte means the server or
            // the network is gone — and a reconnect should start, not a wait.
            config.timeoutIntervalForRequest = 10
            session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        }
        var req = URLRequest(url: url)
        req.setValue("1", forHTTPHeaderField: "Icy-MetaData")   // harmless if unsupported
        let t = session!.dataTask(with: req)
        task = t
        t.resume()
    }

    private func teardownLocked() {
        task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
        stopObservingEngineConfiguration()
        discardScheduledLocked()
        if engine.isRunning { engine.stop() }
        decoder?.close(); decoder = nil
        pending = nil
    }

    /// Drop everything scheduled; completions of the dropped buffers are ignored.
    private func discardScheduledLocked() {
        bufferGeneration &+= 1
        node.stop()
        bufferedFrames = 0
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

    // MARK: - Reconnect

    /// The connection ended — server closed, network blip, idle timeout. Keep
    /// what is already buffered playing, and try again with backoff.
    private func connectionLostLocked(reason: String) {
        reconnectAttempt += 1
        guard let delay = oggReconnectDelay(attempt: reconnectAttempt) else {
            fail("Lost the stream from the server (\(reason)).")
            return
        }
        task = nil
        setState(.reconnecting(attempt: reconnectAttempt))
        let attempt = reconnectAttempt
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.state == .reconnecting(attempt: attempt) else { return }
            self.connectLocked()
        }
    }

    // MARK: - Engine

    private func observeEngineConfiguration() {
        guard configObserver == nil else { return }
        // iOS stops the engine on a hardware configuration change (a Bluetooth
        // codec switch, AirPlay, a sample-rate change). Unobserved, the player
        // went on "playing" silence — and the next node.play() on the stopped
        // engine raised an exception Swift cannot catch.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { @Sendable [weak self] _ in
            guard let self else { return }
            self.queue.async { self.rebuildEngineLocked() }
        }
    }

    private func stopObservingEngineConfiguration() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
    }

    /// Connect the node for `format`, only when it differs from what is already
    /// connected. MPD's encoder starts a new chained bitstream at every track
    /// change; v1.7 tore the engine down for each one, cutting off the end of
    /// the song and making the next one start from an empty buffer.
    private func configureEngineLocked(format: AVAudioFormat) -> Bool {
        if let current = engineFormat, current == format, engine.isRunning { return true }
        if engineFormat != nil, engineFormat != format {
            // A genuine format change (FLAC at a different rate). The buffered
            // tail is in the old format and cannot play through the new
            // connection; drop it. Rare: same-codec track changes never get here.
            discardScheduledLocked()
        }
        if engine.attachedNodes.contains(node) == false { engine.attach(node) }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engineConfigurations += 1
        engineFormat = format
        policy = OggBufferPolicy(sampleRate: format.sampleRate)
        coalesceFrames = AVAudioFrameCount(format.sampleRate / 10)
        return startEngineLocked()
    }

    private func startEngineLocked() -> Bool {
        guard !engine.isRunning else { return true }
        do {
            try engine.start()
            return true
        } catch {
            fail("Audio engine: \(error.localizedDescription)")
            return false
        }
    }

    /// After a configuration change: reconnect with the current format and go
    /// back to buffering. The live stream keeps arriving, so it refills itself.
    private func rebuildEngineLocked() {
        guard let format = engineFormat, state.isRendering else { return }
        discardScheduledLocked()
        engineFormat = nil
        if configureEngineLocked(format: format), state == .playing { setState(.buffering) }
    }

    /// The one place `node.play()` is called — and never on a stopped engine,
    /// whose exception would be a crash.
    private func playNodeLocked() {
        guard startEngineLocked() else { return }
        node.play()
        lastPlayedBack = Date()
        reconnectAttempt = 0          // audio is flowing again: the budget refills
        setState(.playing)
    }

    // MARK: - Packet handling (on `queue`)

    private func consume(_ bytes: [UInt8]) {
        // Health check on every arrival, which costs nothing extra: data keeps
        // coming but nothing has played back, so the engine died under us.
        if oggStreamStalled(lastPlayedBack: lastPlayedBack, now: Date(), state: state) {
            rebuildEngineLocked()
        }
        demuxer.push(bytes)
        while let packet = demuxer.nextPacket() {
            if packet.startsStream {
                // A new logical bitstream: a chained stream at a track boundary,
                // or the headers again after a reconnect.
                beginBitstream(packet)
                continue
            }
            // Another multiplexed stream, or no decoder for this one.
            guard packet.serial == currentSerial, let decoder else { continue }
            if OggCodecIdentifier.isCommentHeader(packet.data, codec: codec) { continue }
            if let buffer = decoder.decode(packet.data) { collect(buffer) }
        }
    }

    private func beginBitstream(_ packet: OggPacket) {
        let identified = OggCodecIdentifier.identify(firstPacket: packet.data)
        guard identified.isPlayable else {
            fail(HTTPStreamCodecs.unsupportedMessage(for: identified))
            return
        }
        flushPendingLocked()          // the last of the previous track plays out
        bitstreamsBegun += 1
        codec = identified
        currentSerial = packet.serial
        // The decoder is per bitstream — pre-skip and STREAMINFO belong to it.
        decoder?.close(); decoder = nil
        guard let d = OggPacketDecoder(codec: identified) else {
            fail("Could not start the \(identified.displayName) decoder")
            return
        }
        decoder = d
        _ = configureEngineLocked(format: d.format)
    }

    /// Gather decoded audio into ~100 ms buffers; see `pending`.
    private func collect(_ buffer: AVAudioPCMBuffer) {
        if pending == nil, buffer.frameLength >= coalesceFrames {
            schedule(buffer); return           // already big enough (FLAC blocks)
        }
        if let p = pending, p.format != buffer.format || p.frameLength + buffer.frameLength > p.frameCapacity {
            flushPendingLocked()
        }
        if pending == nil {
            pending = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                       frameCapacity: max(coalesceFrames, buffer.frameLength) * 2)
            pending?.frameLength = 0
        }
        guard let p = pending, let src = buffer.floatChannelData, let dst = p.floatChannelData else { return }
        let at = Int(p.frameLength), n = Int(buffer.frameLength)
        for ch in 0..<Int(buffer.format.channelCount) {
            (dst[ch] + at).update(from: src[ch], count: n)
        }
        p.frameLength += buffer.frameLength
        if p.frameLength >= coalesceFrames { flushPendingLocked() }
    }

    private func flushPendingLocked() {
        guard let p = pending, p.frameLength > 0 else { pending = nil; return }
        pending = nil
        schedule(p)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        guard engineFormat != nil, buffer.format == engineFormat else { return }
        let frames = Int(buffer.frameLength)
        // Over the cap: drop rather than let the phone fall ever further behind.
        guard policy.accepts(incomingFrames: frames, bufferedFrames: bufferedFrames) else { return }
        bufferedFrames += frames
        let generation = bufferGeneration
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.playedBack(frames: frames, generation: generation) }
        }
        if !node.isPlaying, state != .suspended, policy.shouldStart(bufferedFrames: bufferedFrames) {
            playNodeLocked()
        }
    }

    private func playedBack(frames: Int, generation: Int) {
        guard generation == bufferGeneration else { return }   // discarded audio
        bufferedFrames = max(0, bufferedFrames - frames)
        lastPlayedBack = Date()
        // Dry: pause and refill to the start level, one clean gap instead of
        // packet-by-packet stutter. Scheduled audio stays queued on the node.
        // Also while reconnecting — otherwise the node "plays" an empty queue
        // and the reconnected audio would start with no cushion at all.
        guard node.isPlaying, policy.isUnderrun(bufferedFrames: bufferedFrames) else { return }
        node.pause()
        if state == .playing { setState(.buffering) }
    }
}

// MARK: - URLSession

nonisolated extension OggStreamPlayer: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // An HTTP error cannot be fixed by retrying — refuse it outright.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            completionHandler(.cancel)
            queue.async { [weak self] in
                guard let self, dataTask === self.task else { return }
                self.fail("The stream answered HTTP \(http.statusCode).")
            }
            return
        }
        completionHandler(.allow)
        // Reconnected. Say so at once: if the buffer carried playback through the
        // gap the node is still playing, otherwise it is refilling.
        queue.async { [weak self] in
            guard let self, dataTask === self.task, case .reconnecting = self.state else { return }
            self.setState(self.node.isPlaying ? .playing : .buffering)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let bytes = [UInt8](data)
        queue.async { [weak self] in
            guard let self, dataTask === self.task else { return }   // a superseded connection
            self.consume(bytes)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async { [weak self] in
            guard let self, task === self.task else { return }       // stale, or our own teardown
            if let error {
                let urlError = error as? URLError
                if urlError?.code == .cancelled { return }
                if let code = urlError?.code, oggStreamErrorIsTransient(code) {
                    self.connectionLostLocked(reason: error.localizedDescription)
                } else {
                    self.fail(error.localizedDescription)
                }
            } else {
                // The server closed the stream: MPD restarting, the httpd output
                // disabled or reopened. Retried rather than taken as the end.
                self.connectionLostLocked(reason: "the server closed the connection")
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
    /// Non-interleaved Float32 at the stream's rate: 48 kHz for Opus (always),
    /// the source file's rate for FLAC.
    let format: AVAudioFormat
    private let converter: AudioConverterRef
    private let channels: UInt32
    private var preSkipRemaining: Int
    private var closed = false
    /// Output room per packet: Opus's 120 ms maximum, or the FLAC block size.
    private let frameCapacity: AVAudioFrameCount

    /// Opus packets are at most 120 ms, which is 5760 frames at 48 kHz.
    static let maxFramesPerPacket: AVAudioFrameCount = 5760

    /// What the input callback returns once its single packet is spent.
    ///
    /// Not `noErr` with zero packets: that tells AudioConverter the *stream* has
    /// ended, after which later fill calls can produce nothing. A non-zero status
    /// ends only the current fill call, and `decode` accepts it as success.
    fileprivate static let packetSpent = OSStatus(bitPattern: 0x7370_6E74)   // 'spnt'

    init?(codec: OggCodec) {
        let rate: Double
        let chans: Int
        let formatID: AudioFormatID
        let framesPerPacket: UInt32
        let preSkip: Int
        let capacity: AVAudioFrameCount
        switch codec {
        case .opus(let head):
            // Opus always decodes at 48 kHz, whatever the original rate was.
            // 960 (20 ms, MPD's default) is only a hint: each packet's TOC says
            // its real length, and the output has room for the 120 ms maximum.
            rate = 48000; chans = head.channels; formatID = kAudioFormatOpus
            framesPerPacket = 960; preSkip = head.preSkip
            capacity = Self.maxFramesPerPacket
        case .flac(let info):
            // The frames-per-packet must be the stream's block size: 0 makes
            // AudioConverterNew refuse the format (v1.7 did exactly that, so
            // FLAC never played) and anything smaller decodes nothing.
            rate = Double(info.sampleRate); chans = info.channels; formatID = kAudioFormatFLAC
            framesPerPacket = UInt32(info.maxBlockSize); preSkip = 0
            capacity = AVAudioFrameCount(info.maxBlockSize)
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
        frameCapacity = capacity
    }

    /// PCM for one packet with any remaining pre-skip removed, or nil when the
    /// packet produced nothing (a header, a malformed packet, or all pre-skip).
    func decode(_ packet: [UInt8]) -> AVAudioPCMBuffer? {
        guard !closed, !packet.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: frameCapacity) else { return nil }
        // An AVAudioPCMBuffer's buffer list advertises `frameLength` bytes, and a
        // new buffer's `frameLength` is zero. Handed over as-is, the converter
        // sees output buffers with no room, writes nothing and still reports
        // success — the first version produced silence this way. Open the full
        // capacity for the fill, then shrink to what was produced.
        buffer.frameLength = buffer.frameCapacity
        var frames = frameCapacity
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
