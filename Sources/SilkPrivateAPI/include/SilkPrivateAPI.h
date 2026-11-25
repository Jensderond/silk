#ifndef SILK_PRIVATE_API_H
#define SILK_PRIVATE_API_H

#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>

// Returns the CGWindowID backing an AX window element. Stable since 10.x; used by
// AeroSpace, yabai, Amethyst, Rectangle, Hammerspoon.
AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *outWindowID);

// True when the SkyLight focus symbols (`_SLPSSetFrontProcessWithOptions`,
// `SLPSPostEventRecordTo`) resolved via dlsym. Resolution happens once, lazily.
bool silk_skylight_focus_available(void);

// yabai's focus path: brings `pid` to the front with `windowID` as its key window
// (`_SLPSSetFrontProcessWithOptions(psn, wid, kCPSUserGenerated)` followed by two
// synthetic make-key-window event records). Does not raise the window; the caller
// performs kAXRaiseAction. Returns false when the symbols are unavailable or a call fails.
bool silk_skylight_focus_window(pid_t pid, CGWindowID windowID);

// Called for every trackpad frame, on a MultitouchSupport thread: how many fingers touch the
// surface and their average position (0…1, x left to right, y bottom to top).
typedef void (*silk_touch_callback)(int fingers, float x, float y);

// Starts reporting touches of every trackpad connected right now (MultitouchSupport, resolved via
// dlsym). Returns false when the framework or a symbol is unavailable or there is no trackpad.
bool silk_multitouch_start(silk_touch_callback callback);
void silk_multitouch_stop(void);

#endif
