# v1.7.2 — plan overview

A small release driven by a user request: [issue #14](https://github.com/mickegris/mikMPD/issues/14),
an A–Z **Songs** view in the Library. The reporter runs mikMPD against a
**Chord Poly on MPD 0.21.11**, so compatibility with 0.21 is a requirement, not
a nice-to-have.

| # | Item | Plan | Needs a live server / device to verify? |
|---|---|---|---|
| 1 | Songs chip in the Library: every track A–Z (or Z–A), tap to play, Add Next / Add / Add to Playlist | [01-songs-library-view.md](01-songs-library-view.md) | **Server** (0.24 live, plus a 0.21 instance); device for the energy check |

## Version and branch

- **Version:** `MARKETING_VERSION` 1.7.1 → **1.7.2**, `CURRENT_PROJECT_VERSION`
  41 → **42**, in the Debug and Release configs of the app target in
  `mikMPD.xcodeproj/project.pbxproj`. Owner's call: a patch number, even though
  it adds a Library destination.
- **Branch:** `v1.7.2` off `main`, merged back with a `Merge v1.7.2 — …` commit.
- The bump lands first as its own commit, then one commit per item.

## Decisions taken with the owner

- Songs chip sits **directly right of Recent** (Albums, Artists, Recent,
  **Songs**, Genres …); CLAUDE.md's "new tabs append" rule is changed to allow it.
- **No artwork** in Songs rows — app and battery stability first.
- **MPD older than 0.21** gets a "needs MPD 0.21 or newer" message, no fallback.
- **One query syntax for every server ≥ 0.21**, no version-switched path — asked
  about and investigated; nothing newer helps (plan 01, "Why one syntax path").

## The finding that shapes the design, briefly

Asking MPD for the list pre-sorted (`find … sort Title window …`) looks like the
obvious build and is wrong: **MPD sorts titles by raw bytes**, verified on the
live 0.24 server. In this library 40 lowercase Metallica titles ("am i evil?",
"blitzkrieg" …) sort *after* Z, every Å/Ä/Ö title after those, and
"Another Brick In The Wall" before "Another Brick in the Wall". A Swedish user
would read that as a broken A–Z. So the server only *pages* the data; the app
sorts it — see plan 01.
