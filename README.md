<img src="Resources/AppIcon.png" alt="Silk app icon" width="128">

# Silk

A tiling window manager for macOS with **AeroSpace's functionality**, made **faster** and
**smooth**: new windows land in their tile within a frame or two, and every move, resize and
workspace switch is animated.

Silk is a drop-in replacement for [AeroSpace](https://github.com/nikitabobko/AeroSpace):

- It reads your existing `~/.aerospace.toml` unchanged — same keys, same commands, same binding
  modes, same workspace/monitor rules.
- The brew `aerospace` CLI keeps working against Silk (Silk speaks AeroSpace's wire protocol on
  AeroSpace's socket), so scripts like `aerospace list-windows --all --format …` don't change.
- It ships its own `silk` CLI with the same subcommands, flags, output and exit codes.

No SIP changes, no scripting additions: Silk uses the public Accessibility API (plus
`_AXUIElementGetWindow`, which every macOS window manager uses).

## Why it is faster

In AeroSpace every Accessibility notification cancels the refresh in flight and starts a new one
that re-reads the window list of *every* running app before laying out. A new window emits a burst
of notifications, so its placement waits for the burst to end and for a full refresh — and one slow
app slows everyone down.

Silk is incremental instead. Each app gets its own thread and observer; a notification carries a
snapshot of the window it is about, the core updates its tree, and the layout is computed once per
main-loop turn and diffed, so only windows that actually move are written. Measured on this
machine (M4 Pro, macOS 26.6, 60 Hz display, 8 apps running, 5 trials each; window-server sampling
every 1–2 ms; times from the window's first appearance on screen):

| | AeroSpace 0.21.3 | Silk |
|---|---|---|
| New window of a running app — starts moving | 23–42 ms | **2–18 ms** |
| New window of a running app — in place¹ | jumps at 62–77 ms | **90 % there at 93–120 ms**, gliding |
| New app process (`open -n`, like `alt-enter`) — in its tile | 114–132 ms | **82–94 ms** |

¹ Silk animates the window from where the app opened it into its tile. The default curve spreads
the glide over about ten frames instead of covering half the distance in the first one, so it
reaches 90 % later than AeroSpace's jump; `curve = [0.16, 1, 0.3, 1]` (the previous default) gets
there sooner, with bigger steps.

Silk column re-measured on macOS 26.6.2 with Ghostty (`new window` via AppleScript; `open -n` for
the new process); the AeroSpace column is from the original run.

## Why it is smooth

- A dedicated animator thread driven by the display link of each screen (60/120 Hz).
- Frame writes are latest-wins per window: a slow app never builds a backlog, it just skips frames.
- The write budget adapts per app from measured AX latency: fast apps get position and size every
  frame, slow ones animate position only, very slow ones snap.
- Retargeting mid-flight (holding `alt-l`) continues from where the window is, never restarts.
- Workspace switches slide the incoming windows into place; nothing flashes.
- Silk's own window writes are recognised and ignored, so it never fights itself, and it gives up
  (instead of fighting forever) when an app insists on its own frame.

## Install

Requirements: macOS 14 or later, Xcode 16+ (Swift 6 toolchain).

```sh
make install          # builds Release, installs /Applications/Silk.app, links the `silk` CLI
open -a Silk
```

On first launch Silk asks for Accessibility permission (System Settings → Privacy & Security →
Accessibility) and starts as soon as it is granted. If AeroSpace is running, Silk offers to quit it —
two tiling window managers fight over every window.

`start-at-login = true` in your config registers Silk as a login item (turn AeroSpace's own
`start-at-login` off, or remove AeroSpace from Login Items, so only one of them starts).

`make uninstall` removes the app and the CLI link.

### Updates

Silk checks GitHub for a newer release shortly after launch and then once a day. When there is
one, a green dot appears on the menu bar label and Silk downloads it in the background. The menu
then offers **Restart to Update to Silk x.y.z**; if you don't choose it, the update installs the
next time Silk quits. **Check for Updates…** in the menu checks right away.

Silk only installs a download that is signed with the same certificate as the running app, so
the Accessibility permission carries over. Debug builds, apps run with `swift run`, and copies
in a folder Silk can't write to only show the dot; the menu item then opens the release page.

## Configuration

Silk looks for, in order: `~/.silk.toml`, `~/.config/silk/silk.toml`, `~/.aerospace.toml`,
`~/.config/aerospace/aerospace.toml`. Everything in the
[AeroSpace guide](https://nikitabobko.github.io/AeroSpace/guide) applies. Silk adds two optional
sections (AeroSpace would reject them, so put them in `~/.silk.toml` if you share files):

```toml
[animations]
enabled = true
duration = 180                 # ms, window move/resize (0–2000)
curve = 'ease-out'             # 'ease-out' | 'hyprland' | 'linear' | 'spring' | [x1, y1, x2, y2] | { response = 0.3, damping = 1.0 }
window-open = 'move'           # 'move' (from where the app opened it) | 'popin' | 'none'
workspace-switch = 'slide'     # 'slide' | 'none'
workspace-duration = 220       # ms
respect-reduce-motion = true   # snap while macOS "Reduce motion" is on

[borders]                      # off by default
enabled = true
width = 2
active-color = '#89b4fa'       # '#RRGGBB', '#RRGGBBAA' or '0xAARRGGBB'
radius = 'auto'                # or a number of points
```

And one top-level option: `focus-backend = 'appkit' | 'skylight'` (`skylight` focuses a specific
window with SkyLight's process API, as yabai does; `appkit`, the default, is AeroSpace's method).

## CLI

```sh
silk list-workspaces --focused
silk workspace 3
silk list-windows --all --format '%{window-id}|%{app-bundle-id}'
silk --help                     # all subcommands; `silk <command> --help` for one
```

`silk` and the brew `aerospace` binary are interchangeable while Silk runs.

## Behaviour notes

- **First window of a just-launched app** jumps into its tile instead of animating: a launching app
  applies frame writes too slowly for a smooth animation, and one jump lands sooner.
- **Workspace switches** slide the *incoming* workspace in; the outgoing one is parked at once.
  macOS keeps at least 40 pt of a window on screen at the left edge (1 pt at the right), so sliding
  windows fully off screen would leave them bunched up at the edge.
- **Hidden windows** are parked in a screen corner, exactly like AeroSpace (Mission Control shows
  them there). Silk records every parked window on disk; if it is killed or crashes, the next launch
  puts them back, and the workspace layout is restored as well.
- **Stage Manager** conflicts with tiling; Silk warns when it is on.
- **Secure input** (password fields, some terminals) pauses all global hotkeys — the menu bar shows
  a lock while it is active.
- Menu bar managers such as Dozer or Bartender may hide Silk's status item; ⌘-drag it to keep it
  visible.

## Troubleshooting

- *Nothing happens / hotkeys don't work*: check the menu bar item. A warning triangle means the
  Accessibility permission is missing — after rebuilding an ad-hoc signed app macOS silently
  invalidates it; remove Silk from the Accessibility list and add it again.
- *Latency questions*: run `SILK_TRACE=1 /Applications/Silk.app/Contents/MacOS/Silk` from a terminal
  (quit Silk first) to log every platform event and layout flush with millisecond timestamps.
- *Config errors* open a window listing every problem with its key path; Silk keeps the last good
  config meanwhile.

## Development

```sh
make build        # swift build (debug)
make test         # 390+ unit tests across all modules
make debug-app    # build/Silk Debug.app (bundle id dev.jensderond.silk.debug, separate state)
make run          # build and launch the debug app
make dmg          # build/Silk-<version>.dmg, the drag-to-Applications install image
make release      # build/Silk-<version>.zip and .dmg, notarized: the GitHub release assets
```

Signing uses `$SILK_SIGN_IDENTITY`, else the keychain's "Developer ID Application" identity for
release builds and the local "Apple Development" identity for debug builds, else ad-hoc. A stable
identity keeps the Accessibility grant across rebuilds.

`make release` notarizes with the `notarytool` keychain profile `$SILK_NOTARY_PROFILE` (default
`silk`), for the team the Developer ID belongs to. Store it once with
`xcrun notarytool store-credentials silk --apple-id <apple id> --team-id <team id>` and an
app-specific password.

The code is split into modules that build and test independently — see
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md):

| Module | Role |
|---|---|
| `SilkConfig` | TOML config (AeroSpace schema + Silk sections), key mapping |
| `SilkCore` | Tree model, layout engine, every AeroSpace command; pure and unit-tested |
| `SilkPlatform` | Accessibility: per-app threads, window snapshots and classification, frame writer, hotkeys |
| `SilkAnimation` | Animator thread, curves and springs, per-app write budget, focus border |
| `SilkIPC` | AeroSpace-compatible socket protocol, `subscribe` streaming |
| `SilkApp` | Engine wiring, menu bar, onboarding, crash safety |
| `silk` | The CLI |

## Credits

Silk ports the window-management model, command semantics, window heuristics and test corpus of
[AeroSpace](https://github.com/nikitabobko/AeroSpace) by Nikita Bobko (MIT). See [LICENSE](LICENSE).
