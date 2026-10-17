#ifndef SILK_PRIVATE_API_H
#define SILK_PRIVATE_API_H

#include <ApplicationServices/ApplicationServices.h>

// Returns the CGWindowID backing an AX window element. Stable since 10.x; used by
// AeroSpace, yabai, Amethyst, Rectangle, Hammerspoon.
AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *outWindowID);

#endif
