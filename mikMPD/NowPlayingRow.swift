// NowPlayingRow.swift
//
// One place that decides whether a row is the playing one, and one place that
// decides what that looks like. Before this, five row types each re-expressed
// the comparison and drew their own indicator, at different sizes and in
// different positions — so the marking was easy to miss in some views and the
// next view added would have had to rediscover the rule below.
import SwiftUI

// MARK: - Match rules

/// A **library listing** row matches the playing track by URI.
///
/// Never by position. Outside the queue a row's `pos` either does not exist or
/// means something else entirely: in `PlaylistDetailView` it is the *playlist*
/// index, which has no relationship to `status.song`. Comparing positions there
/// lights up an arbitrary unrelated row — the failure mode worth avoiding,
/// because it produces **wrong** highlighting rather than missing highlighting.
///
/// Empty matches nothing: with playback stopped and no song loaded,
/// `currentSong.file` is "", which must not mark rows that happen to lack a URI.
nonisolated func isCurrentTrack(file: String, currentFile: String) -> Bool {
    !file.isEmpty && file == currentFile
}

/// A **queue** row matches by position, and only the queue does. A queue can
/// legitimately hold the same file twice; the position is what tells the two
/// entries apart, and MPD's `status` hands it to us directly.
nonisolated func isCurrentQueueRow(pos: Int, playlistPos: Int) -> Bool {
    pos >= 0 && pos == playlistPos
}

/// An **album** row matches when the playing track belongs to it.
///
/// This is not `album == album`. The row on screen shows the disc-collapsed base
/// name, so a playing "X [Disc 2]" has to light up the single collapsed "X" row —
/// hence `albumGroupingKey` on both sides, the same key the lists group by. It is
/// artist-scoped for the same reason album identity is, so one artist's
/// "Greatest Hits" cannot mark another's.
///
/// A track with no album tag matches nothing, which is what stops a radio stream
/// (no album, no artist) from marking every untagged album at once.
///
/// A **compilation** row matches on the directory its tracks share instead: its
/// displayed artist is the "Various Artists" placeholder, which matches no
/// song's tags at all, so an artist comparison could never light it up.
nonisolated func isCurrentAlbum(rowArtist: String, rowAlbum: String,
                                compilationBase: String?, current: MPDSong) -> Bool {
    if let base = compilationBase, !base.isEmpty {
        guard !current.file.isEmpty,
              !current.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              albumGroupingKey(rowAlbum) == albumGroupingKey(current.album)
        else { return false }
        return current.file.hasPrefix(base + "/")
    }
    return isCurrentAlbum(rowArtist: rowArtist, rowAlbum: rowAlbum, current: current)
}

/// The ordinary, artist-scoped case. See the overload above for compilations.
nonisolated func isCurrentAlbum(rowArtist: String, rowAlbum: String, current: MPDSong) -> Bool {
    guard !current.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !rowAlbum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !current.file.isEmpty
    else { return false }
    guard albumGroupingKey(rowAlbum) == albumGroupingKey(current.album) else { return false }
    // Album rows carry an albumartist; the song's mirror of that is
    // `groupingArtist`. An artist-less row (genre listings before 0.21-style
    // grouping) matches on the album alone rather than not at all.
    let rowA = rowArtist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !rowA.isEmpty else { return true }
    return rowA == current.groupingArtist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

// MARK: - Presentation

/// The now-playing marker. One glyph, one size, one tint, everywhere.
struct NowPlayingMarker: View {
    var body: some View {
        Image(systemName: "speaker.wave.2.fill")
            .font(.caption2)
            .foregroundStyle(.tint)
            .accessibilityLabel("Now playing")
    }
}

private struct NowPlayingRowModifier: ViewModifier {
    let isCurrent: Bool
    func body(content: Content) -> some View {
        content.listRowBackground(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

private struct NowPlayingCoverModifier: ViewModifier {
    let isCurrent: Bool
    var cornerRadius: CGFloat = 6
    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 2)
        )
    }
}

extension View {
    /// Tints a list row when it is the playing track. The trailing glyph alone
    /// is easy to miss in a long album or a dense search result — the queue has
    /// always had this tint, and the other lists reading differently is why the
    /// marking looked absent in "some views".
    func nowPlayingRow(_ isCurrent: Bool) -> some View {
        modifier(NowPlayingRowModifier(isCurrent: isCurrent))
    }

    /// Marks an album cover whose album is playing. At grid density an accent
    /// *title* alone is too subtle to notice, so the cover carries a border too.
    func nowPlayingCover(_ isCurrent: Bool, cornerRadius: CGFloat = 6) -> some View {
        modifier(NowPlayingCoverModifier(isCurrent: isCurrent, cornerRadius: cornerRadius))
    }
}
