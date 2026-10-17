# Silk — architecture

Silk is a tiling window manager for macOS. It keeps AeroSpace's model, commands,
config format and CLI (it reads `~/.aerospace.toml` unmodified), and adds two things:

1. **Latency.** A newly created window is placed in its tile within one AX round-trip
   of the `kAXWindowCreatedNotification`, never after a "refresh storm" settles.
2. **Motion.** Window moves/resizes, window open, and workspace switches are animated
   (Hyprland-style curves), with a GPU-drawn focus border that moves in perfect sync.

No SIP changes, no scripting additions. Public AX APIs + `_AXUIElementGetWindow`
(stable private symbol used by every macOS WM).

## Why AeroSpace feels slow when a window appears

Every AX notification in AeroSpace calls `scheduleCancellableCompleteRefreshSession`,
which **cancels** the in-flight refresh and starts a new one that re-queries the
window list of *every* running app (`refreshAllAndGetAliveWindowIds`) before laying out.
A window being created emits a burst (created, focused-changed, main-changed, moved,
resized, title-changed …) and app activation emits more, so the refresh keeps being
cancelled and restarted. The window is placed only after the burst quiets down and
one full refresh completes — commonly 150 ms – 1 s.

## Silk's answer: incremental, event-carrying pipeline

```
 per-app AX thread (SilkPlatform)            main thread (SilkApp glue + SilkCore)            display link (SilkAnimation)
 ───────────────────────────────            ───────────────────────────────────────           ────────────────────────────
 AXObserver callback                         PlatformEvent queue (FIFO, per turn)
   kAXWindowCreated(elem) ───snapshot───▶    world.windowDetected(info)    ──┐
   (1 batched AX read: role, subrole,                                       │ mark dirty
    frame, buttons, title, id)                                              ▼
                                             end of runloop turn: world.computeLayout()
                                               -> LayoutPlan (pure, diffed)  ──▶  Animator.apply(plan)
                                                                                     │ per tick: interpolate
                                                                                     ▼
 FrameSink.submit (latest-wins, per window) ◀──────────────────────────────────── frames
   AXUIElementSetAttributeValue (size,pos)
```

Rules:

* **Events carry data.** The AX callback reads everything needed to classify and place
  the window (one `AXUIElementCopyMultipleAttributeValues`) on the app's own thread and
  posts a value snapshot. Main never blocks on AX.
* **No cancellation storms.** Events mutate the model incrementally. Layout is computed
  once per main-runloop turn (coalesced via a `CFRunLoopObserver` on `.beforeWaiting`),
  so a burst of 10 events in one turn = 1 layout, with zero added delay.
* **Reconciliation is a background safety net**, not the primary path: on app
  activation, on mouse-up, on wake/screen change, and on a slow timer (2 s, only while
  something changed recently), each app worker diffs its `kAXWindows` against known
  windows and emits created/destroyed events for anything missed.
* **Per-app threads.** Each app gets a dedicated thread with its own CFRunLoop hosting
  its AXObserver and executing all AX calls for that app. A hung app (beachball) never
  delays other apps or the main thread. `AXUIElementSetMessagingTimeout` = 1 s per app.
* **Latest-wins frame submission.** Each worker holds at most one pending frame per
  window. If the app is slow to apply frame N, frame N+1 replaces it; we never build a
  backlog (backlogs are what make AX animation look laggy).
* **Enhanced user interface off during writes.** `AXEnhancedUserInterface` (set by
  Grammarly, VoiceOver-ish tools, some password managers) makes Chrome/Firefox animate
  their own AX resizes — slow and janky. Disable around frame writes, restore after.

## Modules (SwiftPM targets)

| Target          | Depends on                 | Contents |
|-----------------|----------------------------|----------|
| `SilkConfig`    | TOMLKit                    | Config model, TOML parsing (AeroSpace schema + Silk extensions), key-name → keycode tables, config file discovery. Commands kept as raw strings. Pure. |
| `SilkCore`      | SilkConfig                 | Tree model (workspaces, containers, windows), normalization, layout engine, command parser + all commands, format strings for `list-*`, window rules. Pure logic; side effects only through the `PlatformActions` protocol. Fully unit-tested with a fake platform. |
| `SilkPlatform`  | AppKit, ApplicationServices, Carbon | AX layer: per-app workers, observers, snapshots, classification heuristics, frame writes, focus/raise, monitors, global NSWorkspace/mouse/screen events, Carbon hotkeys, mouse warp. Knows nothing about trees. |
| `SilkAnimation` | AppKit, QuartzCore         | Display-link driven animator (retargetable, curves, springs), `FrameSink` protocol, focus-border overlay window. Knows nothing about AX or trees. |
| `SilkIPC`       | Foundation                 | Unix-socket wire protocol (length-prefixed JSON), client + server. |
| `SilkApp`       | all of the above           | `Engine` glue, app lifecycle, menu bar, onboarding (AX permission), login item, crash-safe window restore, config-error UI. |
| `silk`          | SilkIPC                    | CLI. `aerospace`-compatible: same subcommands, flags, output, exit codes. |

Language mode Swift 5 (strict concurrency off; we use threads + main-thread
confinement deliberately). macOS 14+ deployment target.

## Coordinate system

Everything outside `SilkPlatform` uses **global top-left-origin points** (AX / CG
convention: origin at top-left of the primary display, y grows downward). `SilkPlatform`
converts NSScreen (bottom-left) frames before they leave the module.

## Threading contract

* `SilkCore` objects: main thread only.
* `SilkPlatform.AppWorker`: one thread per pid; all `AXUIElement` instances for an app
  are created, used, and released on that thread. Public API is thread-safe and
  asynchronous; callbacks to the engine are delivered on main via `DispatchQueue.main`.
* `SilkAnimation.Animator`: main thread; display link callback on main.
* IPC server accepts on a background thread, hops to main to run commands, replies
  from main (commands are fast; no command blocks on AX).

## Core model (SilkCore)

Same semantics as AeroSpace so commands behave identically:

```
Workspace(name)
 ├─ rootTilingContainer : TilingContainer(layout: tiles|accordion, orientation: h|v)
 │    └─ children: [TilingContainer | Window], each with a weight
 ├─ floatingWindows: [Window]
 └─ (special) minimized / macOS-fullscreen / hidden-app windows containers
```

* Every non-leaf keeps **MRU order** of its children (drives focus restore).
* Normalizations (config flags): flatten single-child containers; nested containers get
  opposite orientation.
* New tiling window binds next to the MRU window of the target workspace (AeroSpace rule).
* Monitors: each has exactly one visible workspace. Workspace→monitor force-assignment
  patterns: `main`, `secondary`, `built-in`, 1-based index, case-insensitive regex.
* `persistent-workspaces` never GC'ed; other empty invisible workspaces are GC'ed.

Public surface consumed by the glue (sketch — implementation may refine):

```swift
public typealias WindowID = UInt32

public struct MonitorDescriptor: Equatable { id: UInt32; name: String; frame: CGRect; visibleFrame: CGRect; isMain: Bool; isBuiltIn: Bool }
public enum WindowKind { case tileable, dialog /* floats */, popup /* not managed */ }
public struct DetectedWindow { id, pid, bundleId?, appName?, title, frame, kind, isMinimized, isFullscreen, isAppHidden }

public protocol PlatformActions: AnyObject {
    func focusWindow(_ id: WindowID)
    func closeWindow(_ id: WindowID)
    func setMinimized(_ id: WindowID, _ on: Bool)
    func setNativeFullscreen(_ id: WindowID, _ on: Bool)
    func execAndForget(_ script: String)
    func moveMouse(to point: CGPoint)
    var mouseLocation: CGPoint { get }
    func title(of id: WindowID) -> String          // platform caches; refreshed on kAXTitleChanged
    func runningApps() -> [AppDescriptor]           // list-apps
    func setVolume(...)                             // volume command
}

public final class WindowManager {
    init(config:, platform:, monitors:)
    weak var delegate: WindowManagerDelegate?     // modeChanged, focusedWorkspaceChanged, configReloaded, enabledChanged
    // platform → core
    func windowDetected(_:, isStartup:)
    func windowDestroyed(_:)
    func nativeFocusChanged(window:, pid:)
    func windowFrameChangedByUser(_:, frame:)        // AX moved/resized not caused by us
    func mouseUp(at:)                                // ends drag: swap / re-weight
    func windowStateChanged(_:, minimized:/fullscreen:)
    func appHiddenChanged(pid:, hidden:)
    func appTerminated(pid:)
    func monitorsChanged(_:)
    // commands (hotkeys, IPC, callbacks)
    func run(args: [String], env: CommandEnv, stdin: String) -> CommandResult
    func run(script: String /* e.g. "layout tiles horizontal vertical" */, env:) -> CommandResult
    // layout
    var needsLayout: Bool
    func computeLayout() -> LayoutPlan
}

public struct LayoutPlan {
    var frames: [WindowID: CGRect]           // every managed window on a visible workspace (tiling + floating)
    var hidden: [WindowID: CGPoint]          // invisible-workspace windows: top-left in hide corner
    var newlyPlaced: Set<WindowID>           // first placement since detection → "open" animation
    var userDriven: Set<WindowID>            // currently being dragged/resized by user → never animate
    var workspaceSwitches: [WorkspaceSwitch] // (monitor, from, to, direction) since last plan
    var focusedWindow: WindowID?
}
```

## Animation (SilkAnimation)

* `Animator` keeps, per window, `(from, to, start, duration, curve)`; each display-link
  tick computes interpolated frames for active animations and hands them to the
  `FrameSink` in one batch. **Retargeting**: a new target mid-flight starts from the
  current *presented* frame (springs also carry velocity) — rapid `alt-h/l` spam stays
  fluid instead of queueing.
* Curves: cubic-bezier (Hyprland notation `bezier = 0.05, 0.9, 0.1, 1.05`), named
  presets, critically-damped spring.
* Kinds: `move` (tile changes), `open` (popin from ~85 % centered), `workspace`
  (slide along an axis that does not cross into a neighbouring monitor; outgoing
  windows park in the hide corner on completion).
* Final frame is always written with `final: true` → worker writes size, position,
  size (AeroSpace order, needed for apps that constrain) then reads back once.
* Disabled per config, and automatically skipped for windows being dragged by the user,
  for apps known to resize pathologically slowly (measured: if an app's average frame
  write latency > ~40 ms, its windows snap instead of animating).
* `BorderController`: one transparent click-through NSWindow per screen region, stroke
  drawn with CAShapeLayer, ordered just above the focused window. It follows the
  *animated* frame, so it is always 60/120 fps smooth even when the app is slower.

## Config

Read in order: `~/.silk.toml`, `~/.config/silk/silk.toml`, `~/.aerospace.toml`,
`~/.config/aerospace/aerospace.toml`. AeroSpace keys are parsed with AeroSpace semantics.
Silk-only sections (ignored by AeroSpace if the user shares the file):

```toml
[animations]
enabled = true
duration = 180                 # ms, window move/resize
curve = 'hyprland'             # 'hyprland' | 'ease-out' | 'linear' | 'spring' | [x1, y1, x2, y2]
window-open = 'popin'          # 'popin' | 'none'
workspace-switch = 'slide'     # 'slide' | 'none'
workspace-duration = 220

[borders]
enabled = true
width = 2
active-color = '#89b4fa'
radius = 12
```

Invalid config → keep running with previous config (or defaults on first load) and show
the errors in a window + menu bar badge, like AeroSpace.

## Safety

* On quit / SIGTERM / SIGINT / disable: every window hidden in a corner is moved back
  onto its monitor (synchronous writes with a deadline).
* Refuse to start while AeroSpace is running (offer to quit it).
* Never manage our own windows, the lock screen, or windows of other spaces.
