# Design review notes (input to ARCHITECTURE.md)

Findings from reviewing the first architecture draft against AeroSpace (Oct 2026), yabai,
JankyBorders and Electron sources. ARCHITECTURE.md is authoritative where they differ;
this file keeps the detail and the source references.

## New-window latency in AeroSpace — the four costs

- (a) Full re-query per refresh: `kAXWindows` per app + `_AXUIElementGetWindow` per known window
  (liveness) + `normalizeLayoutReason` reads `AXFullScreen` and `AXMinimized` for every window,
  sequentially awaited on main.
- (b) `layoutRecursive` writes `size,pos,size` to every visible tiling window on every refresh,
  no diff (`layoutRecursive.swift:38`).
- (c) Self-induced storm: those writes echo `kAXMoved`/`kAXResized` (`movedObs`/`resizedObs`),
  each cancelling and restarting the refresh.
- (d) `getOrRegisterAxWindow` returns nil while the left mouse button is down (`MacApp.swift`),
  so windows created during a drag wait for mouse-up.
- No `AXUIElementSetMessagingTimeout` (default 6 s).
- AeroSpace subscribes to `WindowCreated`, `FocusedWindowChanged` (app) and `Destroyed`,
  `Miniaturized`, `Deminiaturized`, `Moved`, `Resized` (window).

## Window tracking edge cases

- `kAXWindows` omits windows on other Spaces and native-fullscreen windows
  (`accessibility.swift:258` comment). Liveness must be destroyed-notification or
  `kAXErrorInvalidUIElement`, never absence.
- Ordered-out windows (Electron `hide()`, Chrome find bar, moved to other Space): valid element,
  not in `kAXWindows`, not on screen per `CGWindowListCreateDescriptionFromArray([id])`
  (`kCGWindowIsOnscreen`).
- Observer registration fails (`kAXErrorCannotComplete` / `NotificationUnsupported`) until the
  app has finished launching / initialised AX: observe `isFinishedLaunching`, retry with backoff.
- Apps that never post `WindowCreated`: app-level `kAXFocusedWindowChanged`/`kAXMainWindowChanged`
  naming an unknown window is the fast fallback; reconcile otherwise.
- One `AXObserver` per app, dispatch on notification name, pass window id via refcon.
- CGWindowIDs are session-monotonic (no reuse). Sheets/drawers are not in `kAXWindows`
  (they post `kAXSheetCreated`) — ignore. Finder desktop = AXWindow without window id
  (`_AXUIElementGetWindow` fails) — ignore. Electron may post `WindowCreated` twice — dedupe.
  Frameless Electron windows have no buttons → AeroSpace floats them; keep parity.
- No AX notification exists for native fullscreen: detect via `kAXResized` +
  `activeSpaceDidChange`, then read `AXFullScreen` for that window only.
- Titles are often empty at creation; on-window-detected rules evaluate once (AeroSpace parity).
- Startup binding: by the monitor under the window's centre (`MacWindow.getOrRegister`), not
  the focused workspace.
- Snapshot read: role, subrole, title, position, size, minimized, fullscreen, close/zoom/
  minimize/fullscreen buttons (+ `AXEnabled`), identifier, `AXMain`, `AXFocused`, window id,
  window layer via `CGWindowListCreateDescriptionFromArray([id])`. Never `CGWindowListCopyWindowInfo`
  per event; never read `kCGWindowName` (needs Screen Recording).
- Classifier: port `AxUiElementWindowType.swift` + `KnownBundleId` special cases verbatim
  (1Password level, Ghostty quick terminal / fullscreen-button rule, Firefox PiP, Chrome
  drag-out race, iTerm2, Emacs posframes, Xcode `open_quickly`, qutebrowser, Zoom, Steam, …)
  and its `axDumps` test corpus (repo root of AeroSpace).

## Animation feasibility (estimates — measure with `silk debug bench-ax`)

- Position write: AppKit 0.3–2 ms; Electron 1–5 ms; JetBrains 3–10 ms (window-server move).
- Size write: GPU terminals 1–5 ms; light AppKit 2–10 ms; Xcode/Safari 10–40 ms;
  Electron 10–60 ms and content lags the frame; JetBrains 20–100 ms. Size writes run a
  synchronous layout+draw inside the app's AX handler; apps in modal loops don't service AX.
- Frame budgets: 16.7 ms at 60 Hz, 8.3 ms on 120 Hz ProMotion. One display link per screen
  (`NSScreen.displayLink(target:selector:)`; `CVDisplayLink` deprecated since 15).
- Popin (85 % → 100 %) shows three states (app frame → small → grow) and stale stretched
  content on Electron; default is "move from initial frame". Popin opt-in, auto-disabled when
  measured size latency > 8 ms.
- Hyprland's `0.05, 0.9, 0.1, 1.05` overshoots: apply to position only, clamp size.
- AeroSpace toggles `AXEnhancedUserInterface` around every write (+2 round trips). Silk: read
  once per app (cache), clear at animation start, restore at end.
- Animator on its own `.userInteractive` thread; main can hitch (IPC, `Process.run` for
  exec-and-forget, config reload). `CALayer` updates from that thread need explicit
  `CATransaction`; `NSWindow` frame/order changes hop to main.
- Coalescing on main: first event schedules one `DispatchQueue.main.async { flush() }`.

## Workspace slide

- Hidden windows already have their size → slide = position writes only (cheap, smooth).
  If layout changed while hidden, apply sizes in the corner first, then slide.
- Windows may extend off left (`x = minX - w + 1`), right (`x = maxX - 1`) or bottom
  (`y = maxY - 1`); top impossible (window server keeps title bar below menu bar).
  Prefer a horizontal edge without neighbour, else bottom, else instant.
- Incoming: one position write to the entry edge in the first tick's batch, then slide in.
  Outgoing: slide to exit edge, then park in AeroSpace's hide corner
  (`monitorToOptimalHideCorner`, `refresh.swift`).
- AeroSpace order: unhide visible first, then hide invisible.
- `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` → snap.

## Hiding (copy AeroSpace)

1-px offset except Zoom (`MacWindow.swift`, issue #527); `visibleRect` not `rect`;
`rect.height - 1` hack in `layoutRecursive.swift:11`; proportional-position memory for floating
windows (`prevUnhiddenProportionalPositionInsideWorkspaceRect`). Known side effects: Mission
Control shows corner windows; 1-px sliver clickable.

## Focus border

- `NSWindow.order(.above, relativeTo: foreignWindowNumber)` works across processes (Electron
  `moveAbove`, JankyBorders uses the same window-server path). Same level required (`.normal`).
  Not sticky: re-issue on activation, focused/main-window change, raise, Space change.
- One border panel for the focused window: `NSPanel` borderless + nonactivating,
  `ignoresMouseEvents`, `collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]`,
  `hasShadow = false`, `CAShapeLayer` even-odd path, stroke drawn outside the window rect.
- Tahoe radii vary (NSConvolutionOverride1 default 26; 26.4 reduced visual radius; toolbar
  windows larger). Calibrate: hidden titled NSWindow, `cacheDisplay` theme frame to bitmap,
  scan top-left diagonal for first opaque pixel. Config `radius = 'auto'` default.

## Focus switching

- AeroSpace `MacApp.nativeFocus`: on the app thread set `kAXMain`, `kAXRaise`, then
  `nsApp.activate(options: .activateIgnoringOtherApps)`. Copy: skip AX when
  `lastNativeFocusedWindowId == windowId || windowsCount == 1` (only if
  `!screensHaveSeparateSpaces || monitors == 1`, macOS bug #101); force-focus on window close when
  next focus is a different app (#65, Reminders guard #201, `MacWindow.garbageCollect`).
- Don't wait: update model + border immediately; activation async; `kAXFocusedWindowChanged`
  is confirmation.
- Opt-in `focus-backend = 'skylight'`: `_SLPSSetFrontProcessWithOptions(&psn, wid,
  kCPSUserGenerated=0x200)` + yabai `window_manager_make_key_window` (two
  `SLPSPostEventRecordTo` records, 0xf8 bytes: `[0x04]=0xf8`, `[0x3a]=0x10`, wid at `0x3c`,
  `[0x08]=0x01` then `0x02`) + `kAXRaise`. Resolve symbols with `dlsym`; verify focus within
  100 ms, else fall back to AppKit path.

## IPC

AeroSpace wire protocol on AeroSpace's socket path `/tmp/bobko.aerospace-<user>.sock` in
addition to Silk's own socket, so brew `aerospace` and scripts work unmodified. Implement
`subscribe`. Env vars `AEROSPACE_WINDOW_ID`, `AEROSPACE_WORKSPACE`,
`AEROSPACE_FOCUSED_WORKSPACE`, `AEROSPACE_PREV_WORKSPACE`; exec-and-forget = `/bin/bash -c`.

## Config parity traps

- `'built-in'` is not special: case-insensitive regex substring on the monitor name
  ("Built-in Retina Display"). `secondary` only resolves with exactly 2 monitors.
- `after-startup-command` runs after initial enumeration completes.
- `on-focused-monitor-changed` fires from `focus.swift:checkOnFocusChangedCallbacks`
  (frozen-vs-last-known comparison, suppressed during startup).

## Production

- TCC: grant keyed on signing identity + bundle id; sign dev builds with a stable Apple
  Development cert; separate debug bundle id; `tccutil reset Accessibility <id>` on stale grant.
  Carbon `RegisterEventHotKey` needs no Input Monitoring. Never use screen capture APIs.
- Crash: hide ledger, frozen-world snapshots, best-effort signal handler, `silk restore-windows`.
- Lock screen: `com.apple.screenIsLocked`/`Unlocked` distributed notifications → freeze model;
  keep `loginwindow` filter. Wake: debounce screen changes ~750 ms; monitors by display UUID.
- `screensHaveSeparateSpaces` on/off both matter. Stage Manager (`com.apple.WindowManager
  GloballyEnabled`) → warn. Secure input (`IsSecureEventInputEnabled`) → indicator.
- 50+ windows: thread per app is fine; never `CGWindowListCopyWindowInfo` per event; destroy AX
  objects in reverse order on app death and stop the run loop. Startup enumeration parallel.
- Clicking the desktop of another monitor focuses its workspace (`GlobalObserver.swift`
  leftMouseUp).
