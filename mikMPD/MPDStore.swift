// MPDStore.swift
//
// One socket, one serial queue (Q).
// Poll timer: 1s, fires on main RunLoop, work dispatched to Q.
// Display timer: 0.1s, fires on main RunLoop, updates elapsed directly on main thread.
//
// Key design decisions:
//   - elapsed/duration/isPlaying are @Published on the store itself
//   - display timer advances elapsed by 0.1s each tick when playing
//   - poll sets elapsed from MPD ground truth (unless seek-locked)
//   - togglePlay captures state synchronously on main thread before dispatching
//   - seek uses `seek <pos> <seconds>` (absolute, requires playlist position)
//   - No command_list, no dual sockets, no @State bridging in views

import SwiftUI
import Combine
import Security
import AVFoundation
import MediaPlayer

final class MPDStore: ObservableObject {

    // MARK: - @Published — all written on main thread

    // Playback primitives — view reads these directly
    @Published var elapsed:     Double = 0
    @Published var duration:    Double = 0
    @Published var isPlaying:   Bool   = false
    @Published var isPaused:    Bool   = false
    @Published var volume:      Int    = 80
    @Published var repeatMode:  Bool   = false
    @Published var randomMode:  Bool   = false
    @Published var singleMode:  Bool   = false
    @Published var consumeMode: Bool   = false
    @Published var playlistPos: Int    = -1
    @Published var currentSongID: String = ""
    @Published var bitrate:     String = ""
    @Published var audioFmt:    String = ""
    @Published var currentPartition: String = ""

    // Other state
    @Published var currentSong     = MPDSong()
    @Published var lyricsState:    LyricsState     = .unavailable
    @Published var queue:          [MPDSong]       = []
    @Published var outputs:        [MPDOutput]     = []
    @Published var outputPartitions: [String: String] = [:] // outputID -> partition (for current view)
    @Published var partitions:     [String]        = []
    @Published var browseItems:    [MPDBrowseItem] = []
    @Published var searchResults:  [MPDSong]       = []
    @Published var albumArtCache:  [String: UIImage] = [:]
    private var artAccessOrder: [String] = []
    private let artCacheLimit = 100
    @Published var isConnected     = false
    @Published var connectionError: String?        = nil
    @Published var isSearching     = false
    @Published private(set) var browsePath         = ""
    
    // Private: canonical mapping of output names to partitions
    private var outputNameToPartition: [String: String] = [:]

    // MARK: - Settings
    // host/portStr/password/httpStreamURL are the *live* connection values;
    // they are loaded from the active MPDServerProfile on switch.
    @AppStorage("mpd_host")     var host:    String = "192.168.1.1"
    @AppStorage("mpd_port")     var portStr: String = "6600"
    var password: String {
        get { KeychainHelper.load(key: Self.passwordKey(forServerID: activeServerID)) ?? "" }
        set { KeychainHelper.save(key: Self.passwordKey(forServerID: activeServerID), value: newValue) }
    }
    nonisolated static func passwordKey(forServerID id: String) -> String {
        id.isEmpty ? "mpd_password" : "mpd_password_\(id)"
    }

    // Saved server profiles (passwords live in the Keychain, not in this JSON)
    @Published var servers: [MPDServerProfile] = [] {
        didSet { UserDefaults.standard.set((try? JSONEncoder().encode(servers)) ?? Data(), forKey: "mpdServers") }
    }
    @Published var activeServerID: String = UserDefaults.standard.string(forKey: "activeServerID") ?? "" {
        didSet { UserDefaults.standard.set(activeServerID, forKey: "activeServerID") }
    }
    @AppStorage("rememberPartitions") private var rememberPartitions: Bool = false
    @AppStorage("lastUsedPartitionName") private var lastUsedPartitionName: String?
    @AppStorage("httpStreamURL") var httpStreamURL: String = ""

    var port: Int { Int(portStr) ?? 6600 }

    // MARK: - Private
    private let socket = MPDSocket()
    private let Q = DispatchQueue(label: "mpd", qos: .userInteractive)
    private var pollTimer:    Timer?
    private var displayTimer: Timer?
    private var bgPollTimer:  DispatchSourceTimer?
    private var artPending:   Set<String> = []
    private static func fallbackArtwork(for song: MPDSong) -> UIImage? {
        UIImage(named: song.fallbackArtAssetName)
    }
    private static let artDiskCacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("albumart")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    nonisolated(unsafe) private var lastSongID = ""  // only meaningfully touched on Q (poll)
    private var lyricsToken   = UUID()   // invalidates in-flight lyric fetches on song change
    private var isReconnecting = false
    private var isRestoringPartition = false
    private var partitionToRestore: String?

    // Seek lock: elapsed from poll is ignored until this date passes
    private var seekLockUntil: Date = .distantPast
    
    // State lock: prevents poll from overwriting isPlaying/isPaused immediately after a command
    private var stateLockUntil: Date = .distantPast

    // MARK: - Init
    init() {
        if let legacy = UserDefaults.standard.string(forKey: "mpd_password"), !legacy.isEmpty {
            KeychainHelper.save(key: "mpd_password", value: legacy)
            UserDefaults.standard.removeObject(forKey: "mpd_password")
        }
        loadServersMigratingIfNeeded()
        connect()
    }

    /// Decode saved server profiles; on first run after the multi-server
    /// update, create one profile from the legacy single-server settings.
    private func loadServersMigratingIfNeeded() {
        if let data = UserDefaults.standard.data(forKey: "mpdServers"),
           let decoded = try? JSONDecoder().decode([MPDServerProfile].self, from: data) {
            servers = decoded
        }
        if servers.isEmpty {
            let profile = migratedLegacyProfile(host: host, portStr: portStr,
                                                streamURL: httpStreamURL,
                                                lastPartition: lastUsedPartitionName)
            if let legacyPW = KeychainHelper.load(key: "mpd_password"), !legacyPW.isEmpty {
                KeychainHelper.save(key: "mpd_password_\(profile.id.uuidString)", value: legacyPW)
            }
            servers = [profile]
            activeServerID = profile.id.uuidString
        } else if activeServerID.isEmpty, let first = servers.first {
            activeServerID = first.id.uuidString
        }
    }

    // MARK: - Connection

    func connect() {
        stopTimers()
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectionError = nil
        }
        let h = host, p = port, pw = password
        // On cold start partitionToRestore is nil; fall back to persisted @AppStorage value
        var pendingRestore = partitionToRestore
        partitionToRestore = nil
        if pendingRestore == nil, rememberPartitions, let saved = lastUsedPartitionName, !saved.isEmpty {
            pendingRestore = saved
        }
        let restorePartition = pendingRestore
        Q.async { [weak self] in
            guard let self else { return }
            do {
                try self.socket.connect(host: h, port: p, password: pw)
                // MPD accepts connections without auth even when a password is
                // required — commands then all ACK with a permission error.
                // Probe here so we fail with a clear message instead of
                // entering the poll/reconnect loop with an unusable socket.
                do {
                    _ = try self.socket.command("status")
                } catch MPDError.ack(let line) where line.hasPrefix("ACK [4@") {
                    self.socket.disconnect()
                    DispatchQueue.main.async {
                        self.connectionError = "This server requires a password"
                    }
                    return
                }
                if let part = restorePartition, !part.isEmpty {
                    _ = try? self.socket.command("partition \"\(part.esc)\"")
                }
                self.poll()
                DispatchQueue.main.async {
                    self.isConnected = true
                    self.startTimers()
                    self.loadAll()
                }
            } catch {
                DispatchQueue.main.async {
                    self.connectionError = error.localizedDescription
                }
            }
        }
    }

    func disconnect() {
        stopTimers()
        if !currentPartition.isEmpty {
            partitionToRestore = currentPartition
        }
        Q.async { self.socket.disconnect() }
        DispatchQueue.main.async { self.isConnected = false }
    }

    // MARK: - Saved servers

    func password(forServer id: UUID) -> String {
        KeychainHelper.load(key: "mpd_password_\(id.uuidString)") ?? ""
    }

    func setPassword(_ pw: String, forServer id: UUID) {
        KeychainHelper.save(key: "mpd_password_\(id.uuidString)", value: pw)
    }

    func addServer(_ profile: MPDServerProfile, password: String) {
        servers.append(profile)
        setPassword(password, forServer: profile.id)
        if servers.count == 1 { switchToServer(profile, force: true) }
    }

    func updateServer(_ profile: MPDServerProfile) {
        guard let idx = servers.firstIndex(where: { $0.id == profile.id }) else { return }
        servers[idx] = profile
        if profile.id.uuidString == activeServerID {
            host = profile.host
            portStr = String(profile.port)
            httpStreamURL = profile.streamURL
            if isPhoneStreaming { stopPhoneStream() }
            disconnect()
            partitionToRestore = nil
            connect()
        }
    }

    func deleteServer(_ profile: MPDServerProfile) {
        servers.removeAll { $0.id == profile.id }
        KeychainHelper.save(key: "mpd_password_\(profile.id.uuidString)", value: "")  // removes the entry
        if profile.id.uuidString == activeServerID {
            if let next = servers.first {
                switchToServer(next, force: true)
            } else {
                activeServerID = ""
                disconnect()
            }
        }
    }

    /// Make a profile the active server and reconnect. `force` reconnects
    /// even if it is already active (used as an explicit reconnect).
    func switchToServer(_ profile: MPDServerProfile, force: Bool = false) {
        guard force || profile.id.uuidString != activeServerID else { return }
        // Remember which partition the outgoing profile was on
        if let idx = servers.firstIndex(where: { $0.id.uuidString == activeServerID }),
           !currentPartition.isEmpty {
            servers[idx].lastPartition = currentPartition
        }
        if isPhoneStreaming { stopPhoneStream() }  // stream URL belongs to the old server
        disconnect()
        partitionToRestore = nil  // don't carry the old server's partition across
        activeServerID = profile.id.uuidString
        host = profile.host
        portStr = String(profile.port)
        httpStreamURL = profile.streamURL
        lastUsedPartitionName = profile.lastPartition.isEmpty ? nil : profile.lastPartition
        resetServerState()
        connect()
    }

    /// Clear server-specific published state so stale data from the previous
    /// server doesn't flash while the new connection loads.
    private func resetServerState() {
        queue = []; currentSong = MPDSong(); currentSongID = ""; lastSongID = ""
        outputs = []; outputPartitions = [:]; outputNameToPartition = [:]; partitions = []
        searchResults = []; browseItems = []; playlists = []
        elapsed = 0; duration = 0; isPlaying = false; isPaused = false
        playlistPos = -1; bitrate = ""; audioFmt = ""; currentPartition = ""
        lyricsState = .unavailable
    }

    // MARK: - Timers

    private func startTimers() {
        stopTimers()

        // Poll: every 1s, fetches ground truth from MPD
        let p = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.Q.async { self.poll() }
        }
        RunLoop.main.add(p, forMode: .common)
        pollTimer = p

        // Display: every 0.1s, smoothly advances elapsed on main thread
        let d = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.tickElapsed()
            }
        }
        RunLoop.main.add(d, forMode: .common)
        displayTimer = d
    }

    private func stopTimers() {
        pollTimer?.invalidate(); pollTimer = nil
        displayTimer?.invalidate(); displayTimer = nil
    }

    /// GCD timer on Q that keeps polling while streaming in background.
    /// RunLoop timers are suspended when the app backgrounds; this is not.
    private func startBgPollTimer() {
        stopBgPollTimer()
        let t = DispatchSource.makeTimerSource(queue: Q)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { @Sendable [weak self] in self?.poll() }
        t.resume()
        bgPollTimer = t
    }

    private func stopBgPollTimer() {
        bgPollTimer?.cancel()
        bgPollTimer = nil
    }

    // Called on main thread every 0.1s
    @MainActor
    private func tickElapsed() {
        guard isPlaying, Date() >= seekLockUntil else { return }
        let next = elapsed + 0.1
        elapsed = duration > 0 ? min(next, duration) : next
    }

    // MARK: - Poll (runs on Q)
    nonisolated private func poll() {
        guard socket.connected else {
            // Socket was disconnected by a failed command — trigger reconnect
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isConnected, !self.isReconnecting else { return }
                self.isConnected = false
                self.stopTimers()
                self.isReconnecting = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.isReconnecting = false
                    self.connect()
                }
            }
            return
        }
        do {
            // Two separate commands — simple and correct
            let sRecs = try socket.command("status")
            let cRecs = try socket.command("currentsong")

            // MPD returns multiple records - merge them all
            var s: MPDRecord = [:]
            for rec in sRecs {
                s.merge(rec) { _, new in new }
            }

            let state   = s["state"]    ?? "stop"
            var elapsed = Double(s["elapsed"]  ?? "0") ?? 0
            var dur     = Double(s["duration"] ?? "0") ?? 0
            // Old MPD: `time: elapsed:duration`
            if elapsed == 0, dur == 0, let t = s["time"] {
                let p = t.split(separator: ":").compactMap { Double($0) }
                if p.count == 2 { elapsed = p[0]; dur = p[1] }
            }
            let vol  = Int(s["volume"]  ?? "80") ?? 80
            let pos  = Int(s["song"]    ?? "-1") ?? -1
            let sid  = s["songid"]  ?? ""
            let br   = s["bitrate"] ?? ""
            let af   = s["audio"]   ?? ""
            let rep  = s["repeat"]  == "1"
            let ran  = s["random"]  == "1"
            let sin  = s["single"]  == "1"
            let con  = s["consume"] == "1"
            let curPartition = s["partition"] ?? ""

            let song        = cRecs.first.map { MPDSong($0) } ?? MPDSong()
            let songChanged = song.songID != self.lastSongID
            if songChanged { self.lastSongID = song.songID }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                
                // Only update play/pause state if not locked
                if Date() >= self.stateLockUntil {
                    let newPlaying = (state == "play")
                    let newPaused  = (state == "pause")
                    if self.isPlaying != newPlaying { self.isPlaying = newPlaying }
                    if self.isPaused  != newPaused  { self.isPaused  = newPaused }
                }

                // Only fire @Published setters when values actually change
                // to avoid unnecessary SwiftUI view re-evaluations
                if self.duration     != dur { self.duration     = dur }
                if self.volume       != vol { self.volume       = vol }
                if self.playlistPos  != pos { self.playlistPos  = pos }
                if self.currentSongID != sid { self.currentSongID = sid }
                if self.bitrate      != br  { self.bitrate      = br }
                if self.audioFmt     != af  { self.audioFmt     = af }

                let previousPartition = self.currentPartition
                if self.currentPartition != curPartition { self.currentPartition = curPartition }
                if self.rememberPartitions, (self.lastUsedPartitionName == nil || self.lastUsedPartitionName?.isEmpty == true), !curPartition.isEmpty {
                    self.lastUsedPartitionName = curPartition
                }
                if self.rememberPartitions, !curPartition.isEmpty, curPartition != previousPartition {
                    self.lastUsedPartitionName = curPartition
                }

                if self.repeatMode   != rep { self.repeatMode   = rep }
                if self.randomMode   != ran { self.randomMode   = ran }
                if self.singleMode   != sin { self.singleMode   = sin }
                if self.consumeMode  != con { self.consumeMode  = con }
                if self.currentSong  != song { self.currentSong = song }
                // Only update elapsed from poll when not seek-locked
                if Date() >= self.seekLockUntil {
                    self.elapsed = elapsed
                }
                if songChanged { self.fetchArt(for: song); self.fetchLyrics(for: song) }
                if self.isPhoneStreaming { self.updateNowPlayingInfo() }
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isReconnecting else { return }
                self.isConnected = false
                self.stopTimers()
                self.isReconnecting = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.isReconnecting = false
                    self.connect()
                }
            }
        }
    }

    /// Get playlist length from status — much cheaper than fetching the full playlistinfo.
    nonisolated private func playlistLength() -> Int {
        guard let recs = try? socket.command("status") else { return 0 }
        var s: MPDRecord = [:]
        for rec in recs { s.merge(rec) { _, new in new } }
        return Int(s["playlistlength"] ?? "0") ?? 0
    }

    private func pollSoon() {
        Q.async { [weak self] in self?.poll() }
    }

    // MARK: - Load

    func loadAll() { loadQueue(); loadOutputs(); loadPartitions(); browse("") }

    func loadQueue() {
        Q.async { [weak self] in
            guard let self else { return }
            let songs = (try? self.socket.command("playlistinfo"))?.map { MPDSong($0) } ?? []
            DispatchQueue.main.async { self.queue = songs }
        }
    }

    func loadOutputs() {
        Q.async { [weak self] in
            guard let self else { return }
            let recs = (try? self.socket.command("outputs")) ?? []
            // MPD leaves a "dummy" placeholder in the source partition after
            // moveoutput; hide those so moved outputs don't appear twice.
            let outs = recs.map { MPDOutput($0) }.filter { $0.plugin != "dummy" }
            // Build a mapping from outputID to partition if present in the record
            var partsMap: [String: String] = [:]
            for r in recs {
                if let oid = r["outputid"], let part = r["partition"], !oid.isEmpty, !part.isEmpty {
                    partsMap[oid] = part
                }
            }
            DispatchQueue.main.async {
                self.outputs = outs
                self.updateOutputPartitionsFromNames()
                
                if !partsMap.isEmpty {
                    self.outputPartitions = partsMap
                } else if !self.partitions.isEmpty && self.isConnected && self.outputNameToPartition.isEmpty {
                    self.rebuildOutputPartitionsByProbing()
                }
            }
        }
    }
    
    // Helper: update outputPartitions from the canonical name-based mapping
    @MainActor
    private func updateOutputPartitionsFromNames() {
        var map: [String: String] = [:]
        for out in outputs {
            if let partition = outputNameToPartition[out.name] {
                map[out.outputID] = partition
            }
        }
        if !map.isEmpty {
            outputPartitions = map
        }
    }

    func loadPartitions() {
        Q.async { [weak self] in
            guard let self else { return }
            let parts = (try? self.socket.command("listpartitions"))?.compactMap { $0["partition"] } ?? []
            DispatchQueue.main.async {
                self.partitions = parts
                self.restorePartitionIfNeeded()
            }
        }
    }

    // MARK: - Browse

    func browse(_ path: String) {
        DispatchQueue.main.async { self.browsePath = path }
        let cmd = path.isEmpty ? "lsinfo" : "lsinfo \"\(path.esc)\""
        Q.async { [weak self] in
            guard let self else { return }
            var items: [MPDBrowseItem] = []
            for r in (try? self.socket.command(cmd)) ?? [] {
                if let d = r["directory"]     { items.append(MPDBrowseItem(kind: .directory, path: d)) }
                else if let f = r["file"]     { items.append(MPDBrowseItem(kind: .file,      path: f)) }
                else if let p = r["playlist"] { items.append(MPDBrowseItem(kind: .playlist,  path: p)) }
            }
            DispatchQueue.main.async { self.browseItems = items }
        }
    }

    func browseUp() {
        let parent = browsePath.contains("/")
            ? browsePath.components(separatedBy: "/").dropLast().joined(separator: "/")
            : ""
        browse(parent)
    }

    var isAtRoot: Bool { browsePath.isEmpty }

    // MARK: - Library

    func listTag(_ tag: String, filter: String? = nil, value: String? = nil, completion: @escaping @MainActor ([String]) -> Void) {
        Q.async { [weak self] in
            guard let self else { return }
            var cmd = "list \(tag)"
            if let f = filter, let v = value, !v.isEmpty { cmd += " \(f) \"\(v.esc)\"" }
            let vals = (try? self.socket.listValues(cmd, key: tag)) ?? []
            let sorted = vals.filter { !$0.isEmpty }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            DispatchQueue.main.async { completion(sorted) }
        }
    }

    func findSongs(tag: String, value: String, album: String? = nil, completion: @escaping @MainActor ([MPDSong]) -> Void) {
        Q.async { [weak self] in
            guard let self else { return }
            var cmd = "find \(tag) \"\(value.esc)\""
            if let a = album, !a.isEmpty { cmd += " album \"\(a.esc)\"" }
            let raw = (try? self.socket.command(cmd))?.map { MPDSong($0) } ?? []
            let sorted = raw.sorted { a, b in
                a.album != b.album ? a.album < b.album : a.trackNumber < b.trackNumber
            }
            DispatchQueue.main.async { completion(sorted) }
        }
    }

    func albumSongs(album: String, artist: String? = nil, completion: @escaping @MainActor ([MPDSong]) -> Void) {
        Q.async { [weak self] in
            guard let self else { return }
            var cmd = "find album \"\(album.esc)\""
            if let a = artist, !a.isEmpty { cmd += " artist \"\(a.esc)\"" }
            let songs = sortedByDiscAndTrack((try? self.socket.command(cmd))?.map { MPDSong($0) } ?? [])
            DispatchQueue.main.async { completion(songs) }
        }
    }

    func search(field: String, query: String) {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        DispatchQueue.main.async { self.isSearching = true }
        Q.async { [weak self] in
            guard let self else { return }
            let songs = (try? self.socket.command("search \(field) \"\(query.esc)\""))?.map { MPDSong($0) } ?? []
            DispatchQueue.main.async { self.searchResults = songs; self.isSearching = false }
        }
    }

    // MARK: - Playback commands
    //
    // IMPORTANT: all state reads (isPlaying, isPaused, playlistPos) happen on
    // the CALL SITE on the main thread, then are captured into the closure.
    // Never read @Published vars from inside Q.async — they are main-thread state.

    func togglePlay() {
        // Capture state NOW on main thread
        let playing = isPlaying
        let paused  = isPaused

        // Lock state updates from poll for 0.5 seconds
        stateLockUntil = Date().addingTimeInterval(0.5)

        // Optimistic UI update
        DispatchQueue.main.async {
            if playing {
                self.isPlaying = false
                self.isPaused  = true
            } else {
                self.isPlaying = true
                self.isPaused  = false
            }
        }

        Q.async { [weak self] in
            guard let self else { return }
            
            if playing {
                _ = try? self.socket.command("pause")
            } else if paused {
                _ = try? self.socket.command("pause")
            } else {
                _ = try? self.socket.command("play")
            }
            
            // Poll immediately to get new state
            Thread.sleep(forTimeInterval: 0.1)
            self.poll()
        }
    }

    func play(at pos: Int) {
        Q.async { [weak self] in
            _ = try? self?.socket.command("play \(pos)")
            self?.poll()
        }
    }
    
    // Non-mutating browse that just returns items via completion
    func browse(_ path: String, completion: @escaping @MainActor ([MPDBrowseItem]) -> Void) {
        let cmd = path.isEmpty ? "lsinfo" : "lsinfo \"\(path.esc)\""
        Q.async { [weak self] in
            guard let self else { return }
            var items: [MPDBrowseItem] = []
            for r in (try? self.socket.command(cmd)) ?? [] {
                if let d = r["directory"]     { items.append(MPDBrowseItem(kind: .directory, path: d)) }
                else if let f = r["file"]     { items.append(MPDBrowseItem(kind: .file,      path: f)) }
                else if let p = r["playlist"] { items.append(MPDBrowseItem(kind: .playlist,  path: p)) }
            }
            DispatchQueue.main.async { completion(items) }
        }
    }

    func probeCDTracks(completion: @escaping @MainActor ([MPDBrowseItem]) -> Void) {
        Q.async { [weak self] in
            guard let self else { return }
            var items: [MPDBrowseItem] = []
            for i in 1...99 {
                let uri = "cdda:///\(i)"
                do {
                    let result = try self.socket.command("addid \"\(uri.esc)\"")
                    if let id = result.first?["Id"] ?? result.first?["id"] {
                        _ = try? self.socket.command("deleteid \(id)")
                        items.append(MPDBrowseItem(kind: .file, path: uri))
                    } else {
                        break
                    }
                } catch {
                    // ACK from MPD means this track doesn't exist — we're done
                    break
                }
            }
            DispatchQueue.main.async { completion(items) }
        }
    }
    
    func playCD(track: String? = nil) {
        let uri = track ?? "cdda:///"
        Q.async { [weak self] in
            guard let self else { return }
            _ = try? self.socket.command("clear")
            _ = try? self.socket.command("add \"\(uri.esc)\"")
            _ = try? self.socket.command("play 0")
            self.poll()
            DispatchQueue.main.async { self.loadQueue() }
        }
    }

    func addCD(track: String) {
        Q.async { [weak self] in
            guard let self else { return }
            _ = try? self.socket.command("add \"\(track.esc)\"")
            DispatchQueue.main.async { self.loadQueue() }
        }
    }

    func next() {
        Q.async { [weak self] in _ = try? self?.socket.command("next"); self?.poll() }
    }

    func previous() {
        Q.async { [weak self] in _ = try? self?.socket.command("previous"); self?.poll() }
    }

    func stop() {
        Q.async { [weak self] in _ = try? self?.socket.command("stop"); self?.poll() }
    }

    /// Seek using `seek <songpos> <time>` — more universally supported than seekcur.
    func seek(to seconds: Double) {
        let pos  = playlistPos   // capture on main thread
        let secs = max(0, seconds)
        guard pos >= 0 else { return }

        // Optimistic: update elapsed immediately and lock out poll for 2s
        // so the progress bar doesn't snap back while MPD processes the seek
        seekLockUntil = Date().addingTimeInterval(2.0)
        elapsed = secs

        Q.async { [weak self] in
            guard let self else { return }
            _ = try? self.socket.command(String(format: "seek %d %.3f", pos, secs))
            Thread.sleep(forTimeInterval: 0.1)  // brief pause for MPD to process
            self.poll()
        }
    }

    func setVolume(_ v: Double) {
        Q.async { [weak self] in _ = try? self?.socket.command("setvol \(Int(min(max(v,0),100)))") }
    }

    func toggleRepeat()  { let v = repeatMode;  Q.async { [weak self] in _ = try? self?.socket.command("repeat \(v ? 0:1)");  self?.poll() } }
    func toggleRandom()  { let v = randomMode;  Q.async { [weak self] in _ = try? self?.socket.command("random \(v ? 0:1)");  self?.poll() } }
    func toggleSingle()  { let v = singleMode;  Q.async { [weak self] in _ = try? self?.socket.command("single \(v ? 0:1)");  self?.poll() } }
    func toggleConsume() { let v = consumeMode; Q.async { [weak self] in _ = try? self?.socket.command("consume \(v ? 0:1)"); self?.poll() } }

    // MARK: - Queue management

    func clearQueue() {
        Q.async { [weak self] in _ = try? self?.socket.command("clear"); DispatchQueue.main.async { self?.loadQueue() } }
    }

    func add(uri: String) {
        Q.async { [weak self] in _ = try? self?.socket.command("add \"\(uri.esc)\""); DispatchQueue.main.async { self?.loadQueue() } }
    }

    func addAndPlay(uri: String) {
        Q.async { [weak self] in
            guard let self else { return }
            let before = self.playlistLength()
            _ = try? self.socket.command("add \"\(uri.esc)\"")
            _ = try? self.socket.command("play \(before)")
            self.poll()
            DispatchQueue.main.async { self.loadQueue() }
        }
    }

    func delete(at offsets: IndexSet) {
        let sorted = offsets.sorted(by: >)
        Q.async { [weak self] in
            for pos in sorted { _ = try? self?.socket.command("delete \(pos)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.loadQueue() }
        }
    }

    /// Reorder one row using SwiftUI onMove semantics. The queue is reordered
    /// locally first so the row doesn't snap back before the next poll.
    func moveRow(from offsets: IndexSet, to destination: Int) {
        guard let from = offsets.first else { return }
        let to = mpdMoveTarget(from: from, to: destination)
        guard from != to else { return }
        queue.move(fromOffsets: offsets, toOffset: destination)
        for i in queue.indices { queue[i].pos = i }
        if !currentSongID.isEmpty, let cur = queue.firstIndex(where: { $0.songID == currentSongID }) {
            playlistPos = cur
        }
        Q.async { [weak self] in
            _ = try? self?.socket.command("move \(from) \(to)")
            DispatchQueue.main.async { self?.loadQueue() }
        }
    }

    func loadPlaylist(_ name: String, replace: Bool = false, play: Bool = false) {
        Q.async { [weak self] in
            guard let self else { return }
            if replace { _ = try? self.socket.command("clear") }
            _ = try? self.socket.command("load \"\(name.esc)\"")
            if play {
                _ = try? self.socket.command("play 0")
                self.poll()
            }
            DispatchQueue.main.async { self.loadQueue() }
        }
    }

    func enqueue(songs: [MPDSong], replace: Bool = false, playFirst: Bool = false) {
        Q.async { [weak self] in
            guard let self else { return }
            if replace { _ = try? self.socket.command("clear") }
            let before = replace ? 0 : self.playlistLength()
            for s in songs { _ = try? self.socket.command("add \"\(s.file.esc)\"") }
            if playFirst || replace { _ = try? self.socket.command("play \(before)") }
            if playFirst || replace { self.poll() }
            DispatchQueue.main.async { self.loadQueue() }
        }
    }

    // MARK: - Stored playlists

    @Published var playlists: [MPDPlaylist] = []

    func loadPlaylists() {
        Q.async { [weak self] in
            guard let self else { return }
            let recs = (try? self.socket.command("listplaylists")) ?? []
            let lists = recs.compactMap { r -> MPDPlaylist? in
                guard let name = r["playlist"], !name.isEmpty else { return nil }
                return MPDPlaylist(name: name, lastModified: r["last-modified"] ?? "")
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { self.playlists = lists }
        }
    }

    func playlistSongs(name: String, completion: @escaping @MainActor ([MPDSong]) -> Void) {
        Q.async { [weak self] in
            guard let self else { return }
            let recs = (try? self.socket.command("listplaylistinfo \"\(name.esc)\"")) ?? []
            let songs = songsAssigningPositions(recs)
            DispatchQueue.main.async { completion(songs) }
        }
    }

    /// Append URIs to a playlist; MPD creates the playlist if it doesn't exist.
    func addToPlaylist(name: String, uris: [String]) {
        guard !uris.isEmpty else { return }
        Q.async { [weak self] in
            guard let self else { return }
            for uri in uris { _ = try? self.socket.command("playlistadd \"\(name.esc)\" \"\(uri.esc)\"") }
            DispatchQueue.main.async { self.loadPlaylists() }
        }
    }

    func removeFromPlaylist(name: String, at offsets: IndexSet, completion: @escaping @MainActor () -> Void) {
        let sorted = offsets.sorted(by: >)
        Q.async { [weak self] in
            guard let self else { return }
            for pos in sorted { _ = try? self.socket.command("playlistdelete \"\(name.esc)\" \(pos)") }
            DispatchQueue.main.async { completion() }
        }
    }

    /// Reorder one row using SwiftUI onMove semantics (see moveRow).
    func movePlaylistSong(name: String, from offsets: IndexSet, to destination: Int, completion: @escaping @MainActor () -> Void) {
        guard let from = offsets.first else { return }
        let to = mpdMoveTarget(from: from, to: destination)
        guard from != to else { completion(); return }
        Q.async { [weak self] in
            _ = try? self?.socket.command("playlistmove \"\(name.esc)\" \(from) \(to)")
            DispatchQueue.main.async { completion() }
        }
    }

    func renamePlaylist(_ old: String, to new: String, completion: @escaping @MainActor (String?) -> Void) {
        Q.async { [weak self] in
            guard let self else { return }
            var failure: String?
            do { _ = try self.socket.command("rename \"\(old.esc)\" \"\(new.esc)\"") }
            catch { failure = Self.ackMessage(error.localizedDescription) }
            DispatchQueue.main.async {
                self.loadPlaylists()
                completion(failure)
            }
        }
    }

    func deletePlaylist(name: String) {
        Q.async { [weak self] in
            _ = try? self?.socket.command("rm \"\(name.esc)\"")
            DispatchQueue.main.async { self?.loadPlaylists() }
        }
    }

    func saveQueueAsPlaylist(name: String, completion: @escaping @MainActor (String?) -> Void) {
        Q.async { [weak self] in
            guard let self else { return }
            var failure: String?
            do { _ = try self.socket.command("save \"\(name.esc)\"") }
            catch { failure = Self.ackMessage(error.localizedDescription) }
            DispatchQueue.main.async {
                self.loadPlaylists()
                completion(failure)
            }
        }
    }

    /// Replace the queue with the playlist and start at the given index —
    /// tapping a playlist row plays that song in its playlist context.
    func playPlaylist(name: String, at index: Int) {
        Q.async { [weak self] in
            guard let self else { return }
            _ = try? self.socket.command("clear")
            _ = try? self.socket.command("load \"\(name.esc)\"")
            _ = try? self.socket.command("play \(index)")
            self.poll()
            DispatchQueue.main.async { self.loadQueue() }
        }
    }

    // MARK: - Outputs / Partitions

    func toggleOutput(_ id: String) {
        let enabled = outputs.first(where: { $0.outputID == id })?.enabled ?? false
        Q.async { [weak self] in
            _ = try? self?.socket.command("\(enabled ? "disable" : "enable")output \(id)")
            DispatchQueue.main.async { self?.loadOutputs() }
        }
    }

    func moveOutputToCurrentPartition(_ id: String) {
        moveOutputToPartition(id, targetPartition: currentPartition)
    }
    
    func moveOutputToPartition(_ id: String, targetPartition: String) {
        let originalPartition = currentPartition
        
        guard !targetPartition.isEmpty else { return }
        guard let outputName = outputs.first(where: { $0.outputID == id })?.name else { return }
        
        Q.async { [weak self] in
            guard let self else { return }
            do {
                let partCmd = "partition \"\(targetPartition.esc)\""
                _ = try self.socket.command(partCmd)
                Thread.sleep(forTimeInterval: 0.1)
                
                let moveCmd = "moveoutput \"\(outputName.esc)\""
                _ = try self.socket.command(moveCmd)
                
                if !originalPartition.isEmpty {
                    _ = try? self.socket.command("partition \"\(originalPartition.esc)\"")
                }

                DispatchQueue.main.async {
                    self.outputNameToPartition[outputName] = targetPartition
                }
            } catch {
                if !originalPartition.isEmpty {
                    _ = try? self.socket.command("partition \"\(originalPartition.esc)\"")
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
            DispatchQueue.main.async {
                self.loadOutputs()
            }
        }
    }

    /// Human-readable text from an MPD ACK line, e.g.
    /// `ACK [50@0] {delpartition} it's not empty` → "it's not empty".
    nonisolated static func ackMessage(_ line: String) -> String {
        guard line.hasPrefix("ACK"), let brace = line.range(of: "} ") else { return line }
        return String(line[brace.upperBound...])
    }

    /// Create a partition. Calls completion on main with nil on success or an error message.
    func createPartition(_ name: String, completion: @escaping @MainActor (String?) -> Void) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion("Name must not be empty"); return }
        guard !partitions.contains(trimmed) else { completion("A partition named “\(trimmed)” already exists"); return }
        Q.async { [weak self] in
            guard let self else { return }
            var failure: String?
            do { _ = try self.socket.command("newpartition \"\(trimmed.esc)\"") }
            catch { failure = Self.ackMessage(error.localizedDescription) }
            DispatchQueue.main.async {
                self.loadPartitions()
                completion(failure)
            }
        }
    }

    /// Delete a partition. MPD requires it to be empty: no outputs and no
    /// connected clients. Calls completion on main with nil on success.
    func deletePartition(_ name: String, completion: @escaping @MainActor (String?) -> Void) {
        guard name != "default" else { completion("The default partition cannot be deleted"); return }
        guard name != currentPartition else { completion("Switch away from “\(name)” before deleting it"); return }
        Q.async { [weak self] in
            guard let self else { return }
            var failure: String?
            do { _ = try self.socket.command("delpartition \"\(name.esc)\"") }
            catch { failure = Self.ackMessage(error.localizedDescription) }
            DispatchQueue.main.async {
                if failure == nil, self.lastUsedPartitionName == name {
                    self.lastUsedPartitionName = "default"
                }
                self.loadPartitions()
                self.loadOutputs()
                completion(failure)
            }
        }
    }

    func switchPartition(_ name: String) {
        if rememberPartitions {
            lastUsedPartitionName = name
        }
        
        Q.async { [weak self] in
            guard let self else { return }
            do {
                _ = try self.socket.command("partition \"\(name.esc)\"")
                
                DispatchQueue.main.async { [weak self] in
                    self?.currentPartition = name
                }
            } catch {
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loadQueue()
                self.loadOutputs()
                self.loadPartitions()
            }
        }
    }

    private func restorePartitionIfNeeded() {
        // If remember is ON but we don't yet have a remembered name, seed it from the current partition
        if rememberPartitions, (lastUsedPartitionName == nil || lastUsedPartitionName?.isEmpty == true) {
            lastUsedPartitionName = currentPartition
        }
        
        guard rememberPartitions, let saved = lastUsedPartitionName, !saved.isEmpty else { return }
        guard partitions.contains(saved) else { return }
        guard !isRestoringPartition else { return }
        // Only switch if we are not already on the saved partition
        if currentPartition == saved { return }
        isRestoringPartition = true
        switchPartition(saved)
        // Clear the flag shortly after the switch triggers reloads
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isRestoringPartition = false
        }
    }

    // MARK: - Private helper to rebuild outputPartitions map by probing all partitions

    private func rebuildOutputPartitionsByProbing() {
        let original = currentPartition
        let allParts = partitions
        guard !allParts.isEmpty else { return }
        // print("DEBUG probing outputs by partition: parts=\(allParts), original=\(original)")

        Q.async { [weak self] in
            guard let self else { return }

            var outputNameToPartition: [String: String] = [:]

            for part in allParts {
                _ = try? self.socket.command("partition \"\(part.esc)\"")
                let recs = (try? self.socket.command("outputs")) ?? []
                for r in recs {
                    // Dummy placeholders shadow outputs owned by other partitions
                    if r["plugin"] == "dummy" { continue }
                    if let name = r["outputname"], !name.isEmpty {
                        if let existingPart = outputNameToPartition[name], existingPart != "default" {
                            continue
                        }
                        if part != "default" || outputNameToPartition[name] == nil {
                            outputNameToPartition[name] = part
                        }
                    }
                }
            }

            if !original.isEmpty {
                _ = try? self.socket.command("partition \"\(original.esc)\"")
            }

            DispatchQueue.main.async {
                self.outputNameToPartition = outputNameToPartition
                self.updateOutputPartitionsFromNames()
            }
        }
    }

    // MARK: - Art

    func fetchArtIfNeeded(for song: MPDSong) { fetchArt(for: song) }

    func fetchArtIfNeeded(artist: String, album: String) {
        var song = MPDSong()
        song.artist = artist
        song.album = album
        fetchArt(for: song)
    }

    /// Fetch lyrics for the current song from LRCLIB. Prefetched on song change
    /// (like album art) so the Now Playing lyrics view is ready when toggled.
    /// A per-song token prevents a slow response from an old song overwriting a newer one.
    private func fetchLyrics(for song: MPDSong) {
        // Rotate the token first so a stale in-flight fetch can't land after
        // this point, even when we bail out below.
        let token = UUID(); lyricsToken = token
        // No real song (stopped playback) — displayTitle would degenerate to "/".
        guard !song.title.isEmpty || !song.file.isEmpty else {
            lyricsState = .unavailable; return
        }
        let title  = song.title.isEmpty ? song.displayTitle : song.title
        let artist = song.artist, album = song.album, dur = song.duration
        lyricsState = .loading
        Task { [weak self] in
            let result = await LyricsService.shared.fetch(artist: artist, title: title, album: album, duration: dur)
            await MainActor.run {
                guard let self, self.lyricsToken == token else { return }
                self.lyricsState = result.map { .loaded($0) } ?? .unavailable
            }
        }
    }

    private func fetchArt(for song: MPDSong) {
        let key = song.artKey
        guard !key.isEmpty, albumArtCache[key] == nil, !artPending.contains(key) else { return }
        // Check disk cache first
        if let img = Self.loadArtFromDisk(key: key) {
            storeArt(key: key, image: img)
            return
        }
        artPending.insert(key)
        let file = song.file
        Task { [weak self] in
            guard let self else { return }
            // Try MPD-local art first (cover.jpg/png + embedded)
            var img: UIImage?
            if !file.isEmpty {
                img = await self.fetchMPDArt(file: file)
            }
            // Fall back to MusicBrainz/CoverArtArchive
            if img == nil {
                img = await Self.downloadArt(artist: song.artist, album: song.album)
            }
            await MainActor.run {
                self.artPending.remove(key)
                if let img {
                    self.storeArt(key: key, image: img)
                }
            }
        }
    }

    /// Fetch art from MPD via albumart (cover files) then readpicture (embedded).
    private func fetchMPDArt(file: String) async -> UIImage? {
        await withCheckedContinuation { cont in
            Q.async { [weak self] in
                guard let self else { cont.resume(returning: nil); return }
                // albumart: directory-level cover.jpg/png + embedded (MPD 0.21+)
                if let data = try? self.socket.albumArt(uri: file), let img = UIImage(data: data) {
                    cont.resume(returning: img)
                    return
                }
                // readpicture: embedded picture tag (MPD 0.22+)
                if let data = try? self.socket.readPicture(uri: file), let img = UIImage(data: data) {
                    cont.resume(returning: img)
                    return
                }
                cont.resume(returning: nil)
            }
        }
    }

    @MainActor
    private func storeArt(key: String, image: UIImage) {
        artAccessOrder.removeAll { $0 == key }
        artAccessOrder.append(key)
        albumArtCache[key] = image
        while albumArtCache.count > artCacheLimit, let oldest = artAccessOrder.first {
            artAccessOrder.removeFirst()
            albumArtCache.removeValue(forKey: oldest)
        }
        // Persist to disk cache
        Self.saveArtToDisk(key: key, image: image)
    }

    private static func artDiskPath(key: String) -> URL {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return artDiskCacheDir.appendingPathComponent(safe + ".jpg")
    }

    private static func saveArtToDisk(key: String, image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        try? data.write(to: artDiskPath(key: key), options: .atomic)
    }

    private static func loadArtFromDisk(key: String) -> UIImage? {
        guard let data = try? Data(contentsOf: artDiskPath(key: key)) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Phone Streaming

    @Published var isPhoneStreaming = false
    private var streamPlayer: AVPlayer?

    func togglePhoneStream() { isPhoneStreaming ? stopPhoneStream() : startPhoneStream() }

    func startPhoneStream() {
        guard let url = Self.parseStreamURL(httpStreamURL) else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            connectionError = "Audio session: \(error.localizedDescription)"
            return
        }
        stopPhoneStream()
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 30  // buffer 30s ahead for poor connections
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        streamPlayer = player
        player.play()
        isPhoneStreaming = true
        UIApplication.shared.beginReceivingRemoteControlEvents()
        setupRemoteCommands()
        startBgPollTimer()
        updateNowPlayingInfo()
    }

    func stopPhoneStream() {
        streamPlayer?.pause()
        streamPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isPhoneStreaming = false
        UIApplication.shared.endReceivingRemoteControlEvents()
        stopBgPollTimer()
        tearDownRemoteCommands()
    }

    private func setupRemoteCommands() {
        tearDownRemoteCommands()
        let center = MPRemoteCommandCenter.shared()
        let q = self.Q
        let sock = self.socket
        center.playCommand.addTarget { @Sendable _ in
            q.async { _ = try? sock.command("play") }
            return .success
        }
        center.pauseCommand.addTarget { @Sendable _ in
            q.async { _ = try? sock.command("pause 1") }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { @Sendable _ in
            q.async { _ = try? sock.command("pause") }
            return .success
        }
        center.nextTrackCommand.addTarget { @Sendable _ in
            q.async { _ = try? sock.command("next") }
            return .success
        }
        center.previousTrackCommand.addTarget { @Sendable _ in
            q.async { _ = try? sock.command("previous") }
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = false
    }

    private func tearDownRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func updateNowPlayingInfo() {
        guard isPhoneStreaming else { return }
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = currentSong.displayTitle
        info[MPMediaItemPropertyArtist] = currentSong.artist
        info[MPMediaItemPropertyAlbumTitle] = currentSong.album
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if let img = albumArtCache[currentSong.artKey] ?? Self.fallbackArtwork(for: currentSong) {
            // MediaPlayer invokes the request handler on its own queue —
            // it must be @Sendable or the MainActor inference traps there.
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { @Sendable _ in img }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    nonisolated static func parseStreamURL(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let u = URL(string: t),
              let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty else { return nil }
        return u
    }

    /// Escape special characters for use inside a Lucene quoted string.
    /// Escape Lucene special characters for use inside quoted MusicBrainz queries.
    private static func luceneEscape(_ s: String) -> String {
        var result = ""
        for ch in s {
            if "\\\"+-!(){}[]^~*?:/".contains(ch) { result.append("\\") }
            result.append(ch)
        }
        return result
    }
    private static func downloadArt(artist: String, album: String) async -> UIImage? {
        // MusicBrainz stores multi-disc sets as one release, so "X [Disc 2]" or
        // "X [2005 Remaster]" only match with the marker/qualifier stripped.
        // Then normalize Unicode (e.g. … → ...).
        let album = albumLookupTitle(album).normalizedForLookup
        let artist = artist.normalizedForLookup
        // Try progressively looser MusicBrainz queries
        let queries: [String] = [
            // 1. Exact quoted match
            "release:\"\(luceneEscape(album))\" AND artist:\"\(luceneEscape(artist))\"",
            // 2. Unquoted (tokenized) — handles "AC/DC Live" matching "Live" by "AC/DC"
            "release:\(album) AND artist:\(artist)",
            // 3. Album only — handles misspelled artists like "ACDC" for "AC/DC"
            "release:\"\(luceneEscape(album))\"",
        ]
        let strippedArtist = artist.lowercased().filter(\.isLetter)
        for query in queries {
            let mbids = await searchMusicBrainz(query: query, expectedArtist: strippedArtist)
            for mbid in mbids {
                if let img = await fetchCoverArt(mbid: mbid) { return img }
            }
        }
        return nil
    }

    /// Search MusicBrainz for releases. Returns MBIDs of matching releases (up to 5).
    /// When `expectedArtist` is non-empty, filters to releases whose artist matches.
    private static func searchMusicBrainz(query: String, expectedArtist: String) async -> [String] {
        var c = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
        c.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt",   value: "json"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        // URLComponents doesn't encode +, but servers decode it as space
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = c.url else { return [] }
        var req = URLRequest(url: url)
        req.setValue("MPDClient-iOS/1.0", forHTTPHeaderField: "User-Agent")
        guard
            let (data, _)  = try? await URLSession.shared.data(for: req),
            let json       = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let releases   = json["releases"] as? [[String: Any]]
        else { return [] }
        var mbids: [String] = []
        for release in releases {
            guard let mbid = release["id"] as? String else { continue }
            // Validate artist if we have an expected name
            if !expectedArtist.isEmpty,
               let credits = release["artist-credit"] as? [[String: Any]],
               let mbArtist = credits.first?["name"] as? String {
                let strippedMB = mbArtist.lowercased().filter(\.isLetter)
                guard strippedMB.contains(expectedArtist) || expectedArtist.contains(strippedMB) else { continue }
            }
            mbids.append(mbid)
        }
        return mbids
    }

    private static func fetchCoverArt(mbid: String) async -> UIImage? {
        guard let url = URL(string: "https://coverartarchive.org/release/\(mbid)/front-250"),
              let (data, _) = try? await URLSession.shared.data(from: url)
        else { return nil }
        return UIImage(data: data)
    }
}

extension String {
    nonisolated var esc: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Normalize Unicode characters and library sorting conventions for API lookups.
    /// Handles: Unicode → ASCII substitutions, and sort-order articles ("Name, The" → "The Name").
    nonisolated var normalizedForLookup: String {
        var s = replacingOccurrences(of: "\u{2026}", with: "...")  // ellipsis
            .replacingOccurrences(of: "\u{2018}", with: "'")   // left single quote
            .replacingOccurrences(of: "\u{2019}", with: "'")   // right single quote
            .replacingOccurrences(of: "\u{201C}", with: "\"")  // left double quote
            .replacingOccurrences(of: "\u{201D}", with: "\"")  // right double quote
            .replacingOccurrences(of: "\u{2013}", with: "-")   // en dash
            .replacingOccurrences(of: "\u{2014}", with: "-")   // em dash
        // Move trailing sort-order articles to front: "Name, The" → "The Name"
        for suffix in [", The", ", A", ", An"] {
            if s.lowercased().hasSuffix(suffix.lowercased()) {
                let article = String(s.suffix(suffix.count).dropFirst(2)) // drop ", "
                s = article + " " + s.dropLast(suffix.count)
                break
            }
        }
        return s
    }
}

enum KeychainHelper {
    static func save(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        if !value.isEmpty {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrAccount as String: key,
                                     kSecReturnData as String: true,
                                     kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
