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
    @Published var queue:          [MPDSong]       = []
    @Published var outputs:        [MPDOutput]     = []
    @Published var partitions:     [String]        = []
    @Published var browseItems:    [MPDBrowseItem] = []
    @Published var searchResults:  [MPDSong]       = []
    @Published var albumArtCache:  [String: UIImage] = [:]
    @Published var isConnected     = false
    @Published var connectionError: String?        = nil
    @Published var isSearching     = false
    @Published private(set) var browsePath         = ""

    // MARK: - Settings
    @AppStorage("mpd_host")     var host:    String = "192.168.1.1"
    @AppStorage("mpd_port")     var portStr: String = "6600"
    @AppStorage("mpd_password") var password: String = ""
    @AppStorage("rememberPartitions") private var rememberPartitions: Bool = false
    @AppStorage("lastUsedPartitionName") private var lastUsedPartitionName: String?
    @AppStorage("lastSwitchedPartitionName") private var lastSwitchedPartitionName: String?

    var port: Int { Int(portStr) ?? 6600 }

    // MARK: - Private
    private let socket = MPDSocket()
    private let Q = DispatchQueue(label: "mpd", qos: .userInteractive)
    private var pollTimer:    Timer?
    private var displayTimer: Timer?
    private var artPending:   Set<String> = []
    private var lastSongID    = ""
    private var isRestoringPartition = false

    // Seek lock: elapsed from poll is ignored until this date passes
    private var seekLockUntil: Date = .distantPast
    
    // State lock: prevents poll from overwriting isPlaying/isPaused immediately after a command
    private var stateLockUntil: Date = .distantPast

    // MARK: - Init
    init() { connect() }

    // MARK: - Connection

    func connect() {
        stopTimers()
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectionError = nil
        }
        let h = host, p = port, pw = password
        Q.async { [weak self] in
            guard let self else { return }
            do {
                try self.socket.connect(host: h, port: p, password: pw)
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
        Q.async { self.socket.disconnect() }
        DispatchQueue.main.async { self.isConnected = false }
    }

    // MARK: - Timers

    private func startTimers() {
        stopTimers()

        // Poll: every 1s, fetches ground truth from MPD
        let p = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.Q.async { self?.poll() }
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

    // Called on main thread every 0.1s
    @MainActor
    private func tickElapsed() {
        guard isPlaying, Date() >= seekLockUntil else { return }
        let next = elapsed + 0.1
        elapsed = duration > 0 ? min(next, duration) : next
    }

    // MARK: - Poll (runs on Q)
    private func poll() {
        guard socket.connected else { return }
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
                    self.isPlaying    = (state == "play")
                    self.isPaused     = (state == "pause")
                }

                self.duration     = dur
                self.volume       = vol
                self.playlistPos  = pos
                self.currentSongID = sid
                self.bitrate      = br
                self.audioFmt     = af

                let previousPartition = self.currentPartition
                self.currentPartition = curPartition
                if self.rememberPartitions, (self.lastUsedPartitionName == nil || self.lastUsedPartitionName?.isEmpty == true), !curPartition.isEmpty {
                    self.lastUsedPartitionName = curPartition
                }
                if self.rememberPartitions, !curPartition.isEmpty, curPartition != previousPartition {
                    self.lastUsedPartitionName = curPartition
                }

                self.repeatMode   = rep
                self.randomMode   = ran
                self.singleMode   = sin
                self.consumeMode  = con
                self.currentSong  = song
                // Only update elapsed from poll when not seek-locked
                if Date() >= self.seekLockUntil {
                    self.elapsed = elapsed
                }
                if songChanged { self.fetchArt(for: song) }
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isConnected = false
                self.stopTimers()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.connect() }
            }
        }
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
            let outs = (try? self.socket.command("outputs"))?.map { MPDOutput($0) } ?? []
            DispatchQueue.main.async { self.outputs = outs }
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

    func listTag(_ tag: String, filter: String? = nil, value: String? = nil, completion: @escaping ([String]) -> Void) {
        Q.async { [weak self] in
            guard let self else { return }
            var cmd = "list \(tag)"
            if let f = filter, let v = value, !v.isEmpty { cmd += " \(f) \"\(v.esc)\"" }
            let vals = (try? self.socket.listValues(cmd, key: tag)) ?? []
            let sorted = vals.filter { !$0.isEmpty }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            DispatchQueue.main.async { completion(sorted) }
        }
    }

    func findSongs(tag: String, value: String, album: String? = nil, completion: @escaping ([MPDSong]) -> Void) {
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

    func albumSongs(album: String, artist: String? = nil, completion: @escaping ([MPDSong]) -> Void) {
        Q.async { [weak self] in
            guard let self else { return }
            var cmd = "find album \"\(album.esc)\""
            if let a = artist, !a.isEmpty { cmd += " artist \"\(a.esc)\"" }
            let songs = (try? self.socket.command(cmd))?.map { MPDSong($0) }.sorted { $0.trackNumber < $1.trackNumber } ?? []
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
            let before = (try? self.socket.command("playlistinfo"))?.count ?? 0
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

    func loadPlaylist(_ name: String) {
        Q.async { [weak self] in _ = try? self?.socket.command("load \"\(name.esc)\""); DispatchQueue.main.async { self?.loadQueue() } }
    }

    func enqueue(songs: [MPDSong], replace: Bool = false, playFirst: Bool = false) {
        Q.async { [weak self] in
            guard let self else { return }
            if replace { _ = try? self.socket.command("clear") }
            let before = replace ? 0 : ((try? self.socket.command("playlistinfo"))?.count ?? 0)
            for s in songs { _ = try? self.socket.command("add \"\(s.file.esc)\"") }
            if playFirst || replace { _ = try? self.socket.command("play \(before)") }
            if playFirst || replace { self.poll() }
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

    func switchPartition(_ name: String) {
        // If remembering is enabled at the time of switch, also set the remembered name
        if rememberPartitions {
            lastUsedPartitionName = name
        }
        
        Q.async { [weak self] in
            _ = try? self?.socket.command("partition \(name)")
            DispatchQueue.main.async {
                self?.loadOutputs(); self?.loadPartitions()
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

    // MARK: - Art

    func fetchArtIfNeeded(for song: MPDSong) { fetchArt(for: song) }

    private func fetchArt(for song: MPDSong) {
        let key = song.artKey
        guard !key.isEmpty, albumArtCache[key] == nil, !artPending.contains(key) else { return }
        artPending.insert(key)
        Task { [weak self] in
            guard let self else { return }
            let img = await Self.downloadArt(artist: song.artist, album: song.album)
            await MainActor.run { self.artPending.remove(key); if let img { self.albumArtCache[key] = img } }
        }
    }

    private static func downloadArt(artist: String, album: String) async -> UIImage? {
        var c = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
        c.queryItems = [
            URLQueryItem(name: "query", value: "release:\"\(album)\" AND artist:\"\(artist)\""),
            URLQueryItem(name: "fmt",   value: "json"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = c.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("MPDClient-iOS/1.0", forHTTPHeaderField: "User-Agent")
        guard
            let (d1, _)  = try? await URLSession.shared.data(for: req),
            let json     = try? JSONSerialization.jsonObject(with: d1) as? [String: Any],
            let releases = json["releases"] as? [[String: Any]],
            let mbid     = releases.first?["id"] as? String,
            let artURL   = URL(string: "https://coverartarchive.org/release/\(mbid)/front-250"),
            let (d2, _)  = try? await URLSession.shared.data(from: artURL)
        else { return nil }
        return UIImage(data: d2)
    }
}

extension String {
    var esc: String { replacingOccurrences(of: "\"", with: "\\\"") }
}

