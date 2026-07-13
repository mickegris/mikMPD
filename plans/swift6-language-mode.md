# Plan: Migrate to Swift 6 language mode

**Do this last** — after the six feature/bugfix plans land — so concurrency churn isn't
entangled with feature diffs. The project already builds with the Swift 6.x compiler; this
migration only flips the *language mode* (`SWIFT_VERSION = 5.0` → `6.0`) so strict data-race
checking becomes compile errors instead of warnings.

The project is well-positioned: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and
`SWIFT_APPROACHABLE_CONCURRENCY = YES` are already on, so most UI-facing code is already
implicitly MainActor and won't change.

## Build-setting changes (user does these in Xcode — pbxproj must not be edited while Xcode is open)

1. Optional dry run first: set `SWIFT_STRICT_CONCURRENCY = complete` while staying in Swift 5
   mode — surfaces everything as warnings, lets us fix incrementally with a green build.
2. Final: set `SWIFT_VERSION = 6.0` on all targets (app + tests) and remove the strict-
   concurrency override.

## Expected error sites and fixes

### MPDSocket (the main one)
A mutable class created on MainActor but used exclusively on the serial queue `Q`. Strict mode
rejects capturing it in `Q.async` closures. Options, in order of preference:
1. Mark `final class MPDSocket: @unchecked Sendable` and document the invariant "all access on
   Q after connect" (CLAUDE.md already asserts this informally). Lowest churn, honest about the
   design.
2. Convert to an actor — cleaner long-term but forces `await` through MPDStore's synchronous
   `Q.async` call sites and changes the poll/timer architecture. Not worth it in the same pass;
   note as possible follow-up.

### MPDStore
- The ~40 `Q.async { [weak self] … }` closures capture `self` (MainActor-isolated class) and
  call methods like `playlistLength()`/`poll()` from off-main. Today this "works" because the
  methods only touch the socket. Strict mode will flag them: mark the socket-only helpers
  (`poll`, `playlistLength`, plus new ones from these plans) `nonisolated`, keep all `@Published`
  writes inside `DispatchQueue.main.async` / `MainActor.run` as they already are.
- `static` mutable state: `artDiskCacheDir` (immutable `let` — fine), check for any others.
- Timers/`DispatchSourceTimer` callbacks: annotate closures as needed (`@Sendable`).
- `MPRemoteCommandCenter` handlers already capture only `Q` + socket by design — should be close
  to clean.

### Services
- `WikipediaService` is already an actor — likely clean.
- `LyricsService`: check shared-instance isolation; its disk cache I/O happens in `Task`s.
- `KeychainHelper`: stateless enum with static funcs — fine.

### Tests
- Swift Testing runs nonisolated by default; with MainActor default isolation in the test
  target most existing tests already compile. A few may need `@MainActor` (the pattern already
  exists in the suite, e.g. `equatable()`).

## Process

1. User flips `SWIFT_STRICT_CONCURRENCY = complete` (Swift 5 mode) in Xcode.
2. Fix all warnings file-by-file: MPDSocket sendability first, then MPDStore's nonisolated
   split, then services/views.
3. Full test run + manual smoke test (connect, play, seek, partition switch, phone streaming —
   the racy paths).
4. User flips `SWIFT_VERSION = 6.0`, remove the interim setting; build must be clean.
5. Update CLAUDE.md ("Swift 6 language mode; MPDSocket is @unchecked Sendable, all access on Q").

## Risks

- `@unchecked Sendable` is a promise, not a proof — the "socket only on Q" invariant must
  actually hold (it does today; `connect()` builds params on main then hands off).
- Behavioral changes are zero if done right: this migration should be annotations and small
  refactors only, no logic changes. Any fix that requires reordering real work is a smell —
  stop and reassess.
