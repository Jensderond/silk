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

#endif
