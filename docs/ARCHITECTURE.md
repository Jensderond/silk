# Silk — architecture

Silk is a tiling window manager for macOS. Goal: **AeroSpace's functionality, unchanged**
(same tree model, commands, config file, CLI, wire protocol — it reads `~/.aerospace.toml`
as-is and the brew `aerospace` CLI talks to it), but **faster** and **smoother**:

1. **Latency.** A newly created window is placed in its tile within one AX round-trip
   of `kAXWindowCreatedNotification` (budget ≈ 10–40 ms), never after a refresh storm settles.
2. **Motion.** Window moves/resizes, window open and workspace switches animate with
   Hyprland-style curves. Optional (default off) GPU-drawn focus border.

No SIP changes, no scripting additions. Public AX APIs + `_AXUIElementGetWindow`.

## Why AeroSpace is slow to place new windows

Verified in AeroSpace source (`layout/refresh.swift`, `tree/MacApp.swift`):

* Every AX notification → `scheduleCancellableCompleteRefreshSession` → **cancels** the
  in-flight refresh and starts a full one: `kAXWindows` for every app, `_AXUIElementGetWindow`
  per known window, `AXFullScreen` + `AXMinimized` reads for every window, sequentially
  awaited on main. Latency = sum over all apps.
* `layoutRecursive` writes `size,pos,size` to every visible window on every refresh, no diff.
* Those writes echo `kAXMoved`/`kAXResized`, which cancel and restart the refresh again.
* New windows are ignored while the left mouse button is down.
* No `AXUIElementSetMessagingTimeout` → a beachballing app stalls each refresh up to 6 s.

The hard floor: `kAXWindowCreated` arrives after the window is already on screen at the
app's chosen frame, so 1–3 frames at the "wrong" position are unavoidable without a
compositor. Silk turns that jump into a short animated move from the initial frame.

## Pipeline

```
per-app AX thread (SilkPlatform)        main thread (SilkApp Engine + SilkCore)         animator thread (SilkAnimation)
────────────────────────────────        ────────────────────────────────────────        ───────────────────────────────
AXObserver (1 per app)                   PlatformEvent ─▶ WindowManager mutation
 kAXWindowCreated(elem)                  first event in a turn schedules ONE
   └ batched snapshot read ──event──▶    DispatchQueue.main.async { flush() }
 kAXMoved/kAXResized                     flush(): plan = wm.computeLayout() (diffed)
   └ echo filter (ring of our writes)       └──── apply(plan, epoch) ─────────────────▶  per-window tweens, display link
                                                                                         per screen (NSScreen.displayLink)
FrameWriter.submit (latest-wins,  ◀──────────────────── batches of FrameWrite ─────────  per-app budget from measured
  epoch-checked, per window)                                                            write latency (EMA)
```

Rules:

* **Events carry data.** AX callbacks read what is needed (`AXUIElementCopyMultipleAttributeValues`)
  on the app's thread and post value snapshots. Main never blocks on AX.
* **Incremental, coalesced.** Events mutate the model; layout is computed once per main
  queue turn. Only windows whose target changed are written.
* **Reconciliation is a safety net**, adding windows only: after observer registration,
  app activation, app-level focused/main-window change naming an unknown window, global
  left-mouse-up, space change, screen change, wake, unlock, and a 2 s timer while dirty.
  Liveness = `kAXUIElementDestroyed` or a read returning `kAXErrorInvalidUIElement`
  (never "absent from `kAXWindows`" — that omits other-Space and fullscreen windows).
  While the screen is locked neither counts: the window is flagged and re-checked with
  `kAXRole` by the first reconciliation after unlock, so only app termination destroys
  windows while locked. Every destroy is logged (`silk.platform`) with the path that fired.
  Windows still valid but absent and off-screen are **ordered out** (keep tree slot
  info, drop from layout, reinsert when they reappear).
* **Per-app threads**, one `AXObserver` per app, `AXUIElementSetMessagingTimeout` 1 s on
  app and window elements. Observer registration polls every 25 ms for the first half
  second of an app's launch, then backs off (100/250/500/1000/2000 ms). Like AeroSpace,
  an app counts as registered once any required notification is accepted; missing ones
  are retried, with a reconcile when they arrive.
* **Echo suppression.** Each window keeps a ring of its last 8 written frames. A moved/
  resized notification whose read-back frame matches a ring entry (±1 pt, <500 ms) is ours
  and dropped. Otherwise: left mouse down + window is focused → **user manipulation**;
  else **app-driven** change → engine re-asserts the planned frame, at most 3 times per
  2 s per window (fight guard), then leaves it alone until the next explicit layout change.

## Modules (SwiftPM targets)

| Target          | Depends on          | Contents |
|-----------------|---------------------|----------|
| `SilkConfig`    | TOMLDecoder         | Config model, TOML parsing (AeroSpace schema + Silk extensions), key mapping, config discovery. Commands kept as raw strings. Pure. |
| `SilkCore`      | SilkConfig          | Tree model, normalization, layout engine, shell/command parser, every AeroSpace command, `list-*` formats, window rules, focus callbacks, mouse move/resize semantics, frozen-world persistence model. Pure; side effects via `PlatformActions`. Unit-tested with a fake platform. |
| `SilkPlatform`  | SilkPrivateAPI      | AX workers, observers, snapshots, pure classifier (AeroSpace heuristics + axDumps corpus), frame writer with echo filter + latency stats, focus/raise, monitors, global events, Carbon hotkeys, mouse warp. Knows nothing about trees. |
| `SilkAnimation` | AppKit, QuartzCore  | Animator thread, display links, tweens/curves/springs, per-app scheduling, focus border window, corner-radius calibration. Knows nothing about AX or trees. |
| `SilkIPC`       | Foundation          | AeroSpace wire protocol, client + server, both socket paths, `subscribe` streaming. |
| `SilkApp`       | all                 | `Engine` glue, lifecycle, menu bar, onboarding, login item, hide ledger + crash restore, config error UI, lock/sleep handling. |
| `silk`          | SilkIPC             | CLI, argv-compatible with `aerospace`. |

Swift 5 language mode, macOS 14+.

## Shared conventions

* **Coordinates**: global top-left-origin points (AX/CG convention) everywhere outside
  `SilkPlatform`'s NSScreen conversion code.
* **IDs**: `WindowID = UInt32` (CGWindowID), `pid_t` for apps, `MonitorID` = display UUID
  string (stable across reconnects), plus `CGDirectDisplayID` for display links.
* **Threads**: SilkCore and the Engine: main only. AX objects: confined to their app
  thread. Animator: its own thread; talks to main and platform through thread-safe calls.

## Module contracts

These are the seams between independently built modules. Signatures may be refined by
the owning module, but semantics must hold; the Engine adapts.

### SilkPlatform → Engine

```swift
public struct WindowSnapshot: Sendable {          // read on the app thread
    id: UInt32; pid: pid_t; bundleId: String?; appName: String?
    title: String; frame: CGRect?; kind: WindowKind  // .window (tile) / .dialog (float) / .popup (ignore)
    isMinimized: Bool; isFullscreen: Bool; isFocused: Bool; isMain: Bool
    level: Int?                                       // nil = not on screen yet; re-classified later
}
public enum PlatformEvent: Sendable {
    case windowAppeared(WindowSnapshot, discoveredByReconcile: Bool)
    case windowReclassified(WindowSnapshot)
    case windowDestroyed(UInt32)
    case windowOrderedOut(UInt32), windowOrderedIn(UInt32)
    case windowTitleChanged(UInt32, String)
    case windowMinimizedChanged(UInt32, Bool)
    case windowFullscreenChanged(UInt32, Bool)
    case userManipulation(UInt32, frame: CGRect, phase: Phase)   // began / changed / ended (mouse up)
    case appChangedFrame(UInt32, CGRect)                         // not our echo, not the user
    case focusedWindowChanged(pid: pid_t, window: UInt32?)       // AX confirmation of focus
    case appLaunched(pid_t), appTerminated(pid_t), appActivated(pid_t)
    case appHidden(pid_t), appUnhidden(pid_t)
    case monitorsChanged([MonitorInfo])                           // debounced ~750 ms
    case activeSpaceChanged, willSleep, didWake, screenLocked, screenUnlocked
    case leftMouseUp(CGPoint)
}
public final class PlatformService {
    func start(onEvent: @escaping (PlatformEvent) -> Void)            // callbacks on main
    func enumerateAll(completion: @escaping ([WindowSnapshot]) -> Void) // startup, parallel per app
    var monitors: [MonitorInfo]
    // actions (async, never block main)
    func focus(window:, pid:)            // AeroSpace path: AXMain+AXRaise on app thread, then activate
    func raise(window:)
    func close(window:)
    func setMinimized(window:, _:), setFullscreen(window:, _:)
    func unhideApp(pid:)
    func moveMouse(to:)
    var mouseLocation: CGPoint; var isLeftMouseDown: Bool; var isSecureInputEnabled: Bool
    let writer: FrameWriter               // thread-safe; used by the animator thread
    func writeSynchronously(_ frames: [(UInt32, CGRect)], deadline:)  // termination restore
}
public final class FrameWriter {           // thread-safe
    func submit(_ writes: [FrameWrite])     // latest-wins per window, drops stale epochs
    func cancel(window:)
    func cost(window:) -> WriteCost         // EMA ms for position and size writes, recent timeout flag
}
public struct FrameWrite { window: UInt32; frame: CGRect; epoch: UInt64; mode: .final | .intermediate(setSize: Bool, sizeFirst: Bool) }
public struct MonitorInfo { id (UUID string); displayID; name; frame; visibleFrame; isMain; refreshRate }
```

### SilkCore ↔ Engine

```swift
public protocol PlatformActions: AnyObject {
    func focus(window: WindowID, pid: pid_t)
    func close(window: WindowID)
    func setMinimized(window: WindowID, _: Bool)
    func setNativeFullscreen(window: WindowID, _: Bool)
    func unhideApp(pid: pid_t)
    func execAndForget(_ script: String, env: [String: String])  // /bin/bash -c
    func moveMouse(to: CGPoint)
    var mouseLocation: CGPoint { get }
    var isLeftMouseDown: Bool { get }
    func runningApps() -> [AppInfo]
    func setVolume(_:) / volume                    // `volume` command
    func reloadConfig() -> ConfigLoadResult         // `reload-config`
    func broadcast(_ event: ServerEvent)            // `subscribe` clients
}
public final class WindowManager {           // main thread only
    init(config: Config, platform: PlatformActions, monitors: [Monitor])
    // platform → core (mirror PlatformEvent; startup binds by monitor under window centre)
    func windowDetected(_: DetectedWindow, isStartup: Bool)
    func windowDestroyed / OrderedOut / OrderedIn / minimized / fullscreen / title
    func nativeFocusChanged(window:, pid:)
    func userManipulation(window:, frame:, phase:)   // AeroSpace move/resize-with-mouse semantics
    func appHidden/Unhidden/Terminated(pid:)
    func monitorsChanged(_:)
    func applied(window:, presentedFrame:)          // read-back after final write
    // commands (hotkeys, IPC, callbacks); shell syntax as in AeroSpace 0.21
    func run(args: [String], stdin: String, env: CommandEnv) -> CommandResult
    func run(script: String, env: CommandEnv) -> CommandResult
    // layout
    var needsLayout: Bool
    func computeLayout() -> LayoutPlan
    func frozenWorld() -> FrozenWorld; func restore(_: FrozenWorld)   // crash/upgrade persistence
}
public struct LayoutPlan {
    var epoch: UInt64
    var frames: [WindowID: CGRect]            // tiling + floating windows on visible workspaces
    var hidden: [WindowID: HideTarget]        // invisible-workspace windows: monitor visibleRect + corner
    var newlyPlaced: [WindowID: CGRect]       // first placement: app's initial frame (animation start)
    var userDriven: Set<WindowID>             // never animate
    var workspaceSwitches: [WorkspaceSwitch]  // monitor, from, to, slide direction (core picks free edge or .none)
    var focusedWindow: WindowID?
}
```

### SilkAnimation ↔ Engine

```swift
public protocol FrameSink: AnyObject {         // called on the animator thread
    func submit(_ writes: [FrameWrite])
    func cost(window: UInt32) -> WriteCost
}
public final class Animator {
    init(sink: FrameSink, settings: AnimationSettings)
    func update(settings:)
    func apply(_ request: AnimationRequest)    // thread-safe; main posts, animator thread executes
    func presentedFrame(window:) -> CGRect?    // current interpolated frame (for borders, retargeting)
    var onFrame: ((UInt32, CGRect) -> Void)?   // border sync
}
public struct AnimationRequest {               // built by Engine from LayoutPlan + last known frames
    var epoch: UInt64
    var moves: [Move]                          // window, from (presented/known), to, kind: .layout / .open / .workspaceIn / .workspaceOut, screen displayID
    var snaps: [(UInt32, CGRect)]              // apply instantly (final write)
}
public final class BorderController { func show(frame:, windowNumber:), hide(), update(config:) }
```

Animation rules (owned by SilkAnimation):

* Retarget mid-flight from the presented frame (springs keep velocity).
* Per app per tick, budget = one frame interval of the window's screen. Position every
  tick; size every n-th tick with n = ceil(k·sizeLatency / frameInterval); if n > 3 →
  position-only (final size first when shrinking, last when growing). sizeLatency EMA
  > 40 ms or a timeout in the last 5 s → snap.
* Intermediate writes: shrinking → size then position; growing → position then size.
  Final: `size, position, size`, then one read-back.
* Overshooting curves apply overshoot to position only; size is clamped to [from, to].
  The default curve is ease-out without overshoot: tiles sit one gap from the screen
  edges, and the window server clamps a window that overshoots into the menu bar. It is
  quartic (0.25, 1, 0.5, 1): 33 % of a 180 ms move in the first 60 Hz frame, 90 % after
  five. Expo-out (0.16, 1, 0.3, 1) put 47 % in the first frame and 72 % by the second, then
  crept for six frames — measured as a jump followed by a crawl.
* New tweens get a lead-in write with the request: their frame for the coming vsync (one
  frame interval into the curve) instead of waiting for the next tick. Their first tick then
  re-phases the timeline so it advances exactly one frame interval past the lead-in, so a
  move shows curve times 1, 2, 3… frames on consecutive vsyncs however the request lined up
  with vsync. (Measured on a 60 Hz panel: an unpaused display link fires at the next vsync
  and targets the one after; back-dating against the request time instead skipped up to a
  frame of motion on the second frame, where ease-out moves fastest.) A request steps only
  its new tweens; running ones keep their vsync-aligned frames.
* Display links ask for the panel's full refresh rate (`preferredFrameRateRange`).
* Echo notifications are read back even mid-animation. Each read costs 1–4 ms while the app
  applies a move (0.03 ms idle), but skipping them while a window animates made no
  measurable difference to missed frames (live, 60 Hz, Arc + Claude), so mid-animation user
  drags stay detectable. What remains is an occasional single late frame within the first
  2–3 frames of a move, per app, with nothing else queued on its AX thread: app-side.
* Workspace switch: incoming windows slide the last 20 % of the monitor into place
  (position only) and are raised, focused last; outgoing windows park in AeroSpace's
  hide corner one frame later, so the desktop never flashes. A full slide-out is not
  possible: macOS keeps 40 pt of a window on screen at the left edge, 1 pt at the right
  and 32 pt at the bottom, so outgoing windows would bunch up at the edge. Slide
  direction never crosses into a neighbouring monitor; no free edge → instant.
* The first window of an app launched in the last 1.5 s snaps into its tile: a launching
  app applies AX writes too slowly for a smooth tween, and one jump lands sooner.
* `AXEnhancedUserInterface` is cleared once per app at animation start and restored at end.
* Reduce Motion (when `respect-reduce-motion`) → everything snaps.

## Safety & robustness (Engine)

* Hide ledger (`~/Library/Application Support/Silk/state.json`) written atomically on every
  hide/unhide; on launch, any ledger window still parked in a corner is restored.
  Frozen world saved every few seconds and on quit; restored on relaunch.
* SIGTERM/SIGINT/quit/disable: synchronous move-back of hidden windows with a deadline.
* Lock screen: freeze model (ignore destroys), reconcile on unlock. Wake/screens: debounce,
  monitors keyed by display UUID, assignments survive transient disconnects.
* Refuse to start when AeroSpace is running (offer to quit it). Warn on Stage Manager.
  Secure input indicator in the menu bar (Carbon hotkeys stop working).
* TCC: stable signing identity; detect stale grant and `tccutil reset` like AeroSpace.
