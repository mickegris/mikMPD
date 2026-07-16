# Plan: Launch screen with the mikMPD logo

## Today

`INFOPLIST_KEY_UILaunchScreen_Generation = YES` (project.pbxproj, Debug + Release) gives
the app an empty auto-generated launch screen — a blank system-background flash before
ContentView appears. The only logo asset is `MikMPDLogo.imageset`: a single 1024×1024 PNG
registered at 1x, used as in-app fallback art.

## Approach: `UILaunchScreen` Info.plist dict + dedicated launch assets

SwiftUI apps declare launch screens via the `UILaunchScreen` dictionary (no storyboard).
Two gotchas drive the asset work:

1. **The launch image renders centered at its intrinsic point size — never scaled.** The
   existing 1024×1024@1x logo would draw 1024 pt wide (larger than any iPhone screen).
   A dedicated `LaunchLogo` imageset is required at a sensible size, ~180 pt:
   generate 180/360/540 px renditions from the existing PNG
   (`sips -Z 540 MikMPDLogo.png --out LaunchLogo@3x.png`, etc.) and register them at
   1x/2x/3x in the imageset's `Contents.json`. Don't reuse/resize `MikMPDLogo` itself —
   the in-app fallback art wants the full-res original.
2. **Both generated and plist-defined `UILaunchScreen` keys can't coexist** (duplicate-key
   build error). Flip `INFOPLIST_KEY_UILaunchScreen_Generation` to `NO` in both build
   configurations, then define the dict in `mikMPD/Info.plist`:

   ```xml
   <key>UILaunchScreen</key>
   <dict>
       <key>UIImageName</key>
       <string>LaunchLogo</string>
       <key>UIColorName</key>
       <string>LaunchBackground</string>
   </dict>
   ```

**`LaunchBackground.colorset`** — new color asset with Any/Dark appearance variants
matching `systemBackground` (white / black), so the splash doesn't flash white in dark
mode. If the logo PNG turns out to have an opaque background rather than transparency,
either match `LaunchBackground` to that background color exactly or add a dark-appearance
variant image to `LaunchLogo` — check the alpha channel before choosing.

HIG note: Apple nominally recommends launch screens that mimic the first UI rather than
logo splashes, but a centered logo on system background is the conventional music-app
choice and what was asked for; it also can't drift out of sync with UI changes the way a
fake-UI launch screen does.

## Steps

1. Generate the three `LaunchLogo` PNGs with `sips` from
   `Assets.xcassets/MikMPDLogo.imageset/MikMPDLogo.png`; create
   `Assets.xcassets/LaunchLogo.imageset/` with a scales-based `Contents.json`
   (files on disk — the target uses a synchronized group, no pbxproj file entries needed).
2. Create `Assets.xcassets/LaunchBackground.colorset` (Any = systemBackground white,
   Dark = black).
3. Add the `UILaunchScreen` dict to `mikMPD/Info.plist`.
4. Set `INFOPLIST_KEY_UILaunchScreen_Generation = NO` in both configurations. The pbxproj
   has an unrelated pre-existing uncommitted modification — stage only these lines
   (`git add -p`) so the user's change stays out of the commit.

## Verification

No unit-testable logic (assets + plist). Manual, and mind iOS's aggressive launch-screen
caching — **delete the app from the simulator (or reboot it) between iterations**, or the
old cached launch screen keeps showing:

- Fresh install, launch: centered logo at a sane size on system background.
- Repeat with dark appearance: no white flash, logo legible.
- Build must succeed with the generation flag off and the plist dict present (catches the
  duplicate-key conflict).
