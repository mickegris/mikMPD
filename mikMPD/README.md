//
//  MPDModels.swift
//  MPDClient
//
//  Created by User on 2024-04-27.
//

import Foundation

// MARK: - MPDSong

/// Represents a song in the MPD library or queue.
struct MPDSong: Identifiable, Equatable {
    let id: String // Unique identifier for the song, e.g., file path
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval // Duration in seconds
    
    // Computed property for album art cache key: "artist|album"
    var albumArtKey: String {
        "\(artist)|\(album)"
    }
}

// MARK: - MPDOutput

/// Represents an MPD audio output device.
struct MPDOutput: Identifiable, Equatable {
    let id: Int // Output ID from MPD server
    let name: String
    let enabled: Bool
}

// MARK: - MPDBrowseItem

/// Represents an item in the MPD browse view (directory, file, or playlist).
enum MPDBrowseItem: Identifiable, Equatable {
    case directory(name: String)
    case file(song: MPDSong)
    case playlist(name: String)
    
    var id: String {
        switch self {
        case .directory(let name):
            return "dir:\(name)"
        case .file(let song):
            return "file:\(song.id)"
        case .playlist(let name):
            return "playlist:\(name)"
        }
    }
}

// MARK: - Utilities

/// Formats a time interval as "MM:SS" string.
func formatTime(_ duration: TimeInterval) -> String {
    let totalSeconds = Int(duration)
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%02d:%02d", minutes, seconds)
}
