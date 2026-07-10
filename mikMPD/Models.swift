// Models.swift
import Foundation
import UIKit

func artCacheKey(artist: String, album: String) -> String {
    let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedArtist.isEmpty || !trimmedAlbum.isEmpty else { return "" }
    return "\(trimmedArtist)|\(trimmedAlbum)".lowercased()
}

enum PlaybackSourceKind {
    case library
    case radio
    case cd
}

struct MPDSong: Identifiable, Equatable {
    var file:     String = ""
    var title:    String = ""
    var artist:   String = ""
    var album:    String = ""
    var track:    String = ""
    var duration: Double = 0
    var pos:      Int    = 0
    var songID:   String = ""

    var id: String { songID.isEmpty ? "\(pos):\(file)" : songID }
    var displayTitle: String { title.isEmpty ? URL(fileURLWithPath: file).lastPathComponent : title }
    var trackNumber: Int { Int(track.components(separatedBy: "/").first ?? "") ?? 0 }
    var artKey: String { artCacheKey(artist: artist, album: album) }
    var sourceKind: PlaybackSourceKind {
        let trimmedFile = file.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedFile = trimmedFile.lowercased()
        if lowercasedFile.hasPrefix("cdda:") {
            return .cd
        }
        if let scheme = URL(string: trimmedFile)?.scheme?.lowercased(),
           ["http", "https", "icy"].contains(scheme) {
            return .radio
        }
        return .library
    }
    var fallbackArtAssetName: String {
        switch sourceKind {
        case .library: "MikMPDLogo"
        case .radio: "RadioFallbackArt"
        case .cd: "CDFallbackArt"
        }
    }

    init() {}
    init(_ r: MPDRecord) {
        file     = r["file"]     ?? ""
        title    = r["title"]    ?? ""
        artist   = r["artist"]   ?? ""
        album    = r["album"]    ?? ""
        track    = r["track"]    ?? ""
        duration = Double(r["duration"] ?? "0") ?? 0
        pos      = Int(r["pos"]  ?? "0") ?? 0
        songID   = r["id"]       ?? ""
    }
}

struct MPDOutput: Identifiable, Equatable {
    var outputID: String
    var name:     String
    var enabled:  Bool
    var plugin:   String
    var id: String { outputID }
    init(_ r: MPDRecord) {
        outputID = r["outputid"]      ?? UUID().uuidString  // fallback keeps IDs unique
        name     = r["outputname"]    ?? "Output"
        enabled  = r["outputenabled"] == "1"
        plugin   = r["plugin"]        ?? ""
    }
}

struct MPDBrowseItem: Identifiable {
    enum Kind { case directory, file, playlist }
    var kind: Kind
    var path: String
    var id: String { kind == .directory ? "d:\(path)" : kind == .file ? "f:\(path)" : "p:\(path)" }
    var displayName: String { URL(fileURLWithPath: path).lastPathComponent }
    var sfSymbol: String {
        switch kind {
        case .directory: "folder.fill"
        case .file:      "music.note"
        case .playlist:  "list.bullet.rectangle"
        }
    }
}

func formatTime(_ s: Double) -> String {
    guard s > 0, s.isFinite else { return "0:00" }
    let t = Int(s)
    return "\(t / 60):\(String(format: "%02d", t % 60))"
}
