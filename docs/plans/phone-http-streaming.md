# Plan: Listen on Phone — stream an MPD httpd output to the device

## Context

mikMPD is today a **remote control** for MPD: it tells the server what to play on
*home* outputs (ALSA / Snapcast / httpd) but produces no audio on the iPhone itself
(there is no AVFoundation usage anywhere; the README describes it as a "remote
control client only").

The MPD server has an `httpd` audio output reachable over the network (e.g.
`http://mpd.example.com:8080/`). That URL is already a live, playable audio
stream of whatever MPD is currently decoding. The missing piece is simply a
**player on the phone** that "tunes in" to it. This is the coupled-listen model —
like turning on a radio that broadcasts the home server — *not* an independent
Roon-ARC endpoint with its own queue.

Networking (VPN / port-forward) is explicitly **out of scope**; the user reaches the
URL via VPN or port-forwarding on their own.

## ⚠️ Manual steps in Xcode — do not skip

These cannot be done from code edits alone and are easy to forget:

- [ ] **Enable Background Modes → Audio** (target → Signing & Capabilities → +
      Capability → Background Modes → check "Audio, AirPlay, and Picture in
      Picture"). **Without this, playback stops the moment the screen locks or the
      app backgrounds** — i.e. the feature looks broken. See section 4.
- [ ] **Set the httpd output encoder to MP3 (LAME)** on the MPD server — `AVPlayer`
      will not play Ogg/Opus. Server config, not app code. See "Server-side notes".

## Two features to build

1. **Setting** — a text field for the httpd output URL, stored in `UserDefaults`,
   editable in the existing Connection settings screen.
2. **Toggle in Now Playing** — "Listen on phone": when ON, an on-device `AVPlayer`
   plays the configured URL; when OFF, it stops. Independent of MPD transport — the
   existing play / seek / volume controls still drive the *server*, not the phone.

## Architecture grounding

- **Settings pattern**: `@AppStorage("mpd_host")` etc. on `MPDStore`
  (`MPDStore.swift:59-66`). Edited in `ConnectionView` (`SettingsView.swift`),
  presented as a sheet from `MoreView` (`MoreView.swift:60-62`).
- **Single store**: `MPDStore` is the one `ObservableObject`; views read its
  `@Published` state and call its methods. Streaming state belongs here for
  consistency (the store already owns art download, keychain, and the socket).
- **Now Playing layout**: `NowPlayingView` composes subviews in a `VStack`
  (`NowPlayingView.swift:49-57`): `songInfo / seekBar / transportButtons /
  volumeSlider / modeButtons / audioInfo`. The new toggle slots in after
  `audioInfo`.
- **Actor isolation**: default actor isolation is `MainActor`, so AVFoundation
  calls made from view actions run on the main thread — no extra hops needed.

## Implementation

### 1. `MPDStore.swift` — streaming state + player

- Add `import AVFoundation` at the top.
- New setting alongside the other `@AppStorage` properties (~line 59):
  ```swift
  @AppStorage("httpStreamURL") var httpStreamURL: String = ""
  ```
- New `// MARK: - Phone Streaming` section:
  ```swift
  @Published var isPhoneStreaming = false
  private var streamPlayer: AVPlayer?

  func togglePhoneStream() { isPhoneStreaming ? stopPhoneStream() : startPhoneStream() }

  func startPhoneStream() {
      guard let url = Self.parseStreamURL(httpStreamURL) else { return }
      do {
          let session = AVAudioSession.sharedInstance()
          try session.setCategory(.playback, mode: .default)
          try session.setActive(true)
      } catch { connectionError = "Audio session: \(error.localizedDescription)" }
      let player = AVPlayer(url: url)
      player.automaticallyWaitsToMinimizeStalling = true
      streamPlayer = player
      player.play()
      isPhoneStreaming = true
  }

  func stopPhoneStream() {
      streamPlayer?.pause(); streamPlayer = nil
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      isPhoneStreaming = false
  }
  ```
  Rationale for living in `MPDStore`: matches the codebase's single-store design.
  A separate `StreamPlayer` `ObservableObject` is the alternative but adds another
  environment object for little gain.

### 2. `SettingsView.swift` (`ConnectionView`) — the URL field

Add a section after the existing "MPD Server" section (~line 21), binding straight
to the store so it persists immediately via `@AppStorage`:
```swift
Section("Phone Streaming") {
    LabeledContent("Stream URL") {
        TextField("http://host:port/", text: Binding(
            get: { store.httpStreamURL },
            set: { store.httpStreamURL = $0 }))
            .multilineTextAlignment(.trailing)
            .keyboardType(.URL).autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }
    Text("URL of an MPD httpd output. Enable “Listen on phone” in Now Playing to stream it to this device.")
        .font(.caption).foregroundStyle(.secondary)
}
```
No reconnect needed — unlike host/port (committed on "Connect"), the URL is only
read when the toggle fires.

### 3. `NowPlayingView.swift` — the toggle

Add `phoneStreamToggle` to the `VStack` after `audioInfo` (line 55), and define:
```swift
@ViewBuilder
var phoneStreamToggle: some View {
    let hasURL = !store.httpStreamURL.trimmingCharacters(in: .whitespaces).isEmpty
    Button { store.togglePhoneStream() } label: {
        HStack(spacing: 8) {
            Image(systemName: store.isPhoneStreaming ? "iphone.radiowaves.left.and.right" : "iphone")
            Text(store.isPhoneStreaming ? "Streaming to phone" : "Listen on phone")
        }
        .font(.caption)
        .foregroundStyle(store.isPhoneStreaming ? Color.accentColor : .secondary)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(store.isPhoneStreaming
            ? Color.accentColor.opacity(0.15) : Color(.systemGray6)))
    }
    .buttonStyle(.plain)
    .disabled(!hasURL)
    .opacity(hasURL ? 1 : 0.5)
}
```
`isPhoneStreaming` is `@Published`, so the button restyles reactively. When no URL
is set it is disabled (hint: set it under Connection).

### 4. Project capability — background audio (manual Xcode step)

Plain `AVPlayer` playback stops when the app backgrounds/locks unless the **Audio**
background mode is enabled. In Xcode: *target → Signing & Capabilities → +
Capability → Background Modes → check "Audio, AirPlay, and Picture in Picture"*
(adds `UIBackgroundModes = [audio]`). This edits the project and must be done in
Xcode. Without it the feature still works while the app is in the foreground.

### 5. Tests (`mikMPDTests`)

Add a pure, I/O-free helper and one Swift-Testing case (keeps the "test pure logic"
convention):
```swift
extension MPDStore {
    static func parseStreamURL(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let u = URL(string: t), u.scheme != nil else { return nil }
        return u
    }
}
```
`startPhoneStream` uses it; the test covers valid / empty / whitespace /
scheme-less inputs.

## Server-side notes (configuration, no app code)

- **Codec matters.** `AVPlayer` plays live **MP3** streams (shoutcast/ICY style),
  AAC/HLS, ALAC, and FLAC — but **not Ogg Vorbis / Opus**. The httpd output should
  use the LAME (MP3) encoder for best compatibility; FLAC-over-httpd is unreliable.
- The httpd **output must be enabled** on the server for audio to flow — manage it
  via the existing Outputs screen. Phone streaming just tunes in; it does not
  enable the output.
- The phone audio lags the server position by a few seconds of buffer; the seek bar
  keeps showing MPD's ground-truth elapsed. Cosmetic; acceptable for the MVP.
- Device hardware volume controls the phone stream (AVPlayer honors system volume);
  the in-app volume slider still controls MPD. No extra control needed.

## Out of scope (future work)

Lock-screen / Control Center metadata (`MPNowPlayingInfoCenter` +
`MPRemoteCommandCenter`), interruption / route-change handling (calls, unplugging
headphones), and the full Roon-ARC model (independent queue, on-demand per-track
streaming, transcoding, offline downloads). This feature is deliberately the simple
"tune in to the broadcast" path.

## Verification (after implementation)

Requires macOS / Xcode. Build the `mikMPD` scheme; on a device or simulator:

1. Set the Stream URL under **More → Connection**.
2. Start playback on the server's httpd output.
3. Tap **"Listen on phone"** in Now Playing → audio plays on the device.
4. Background the app → audio continues (with the Audio capability enabled).
5. Toggle off → audio stops.

Run the unit tests (Cmd+U) to cover `parseStreamURL`.
