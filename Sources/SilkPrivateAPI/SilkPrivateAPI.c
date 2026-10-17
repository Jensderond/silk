#include "SilkPrivateAPI.h"

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <string.h>

typedef CGError (*SLPSSetFrontProcessWithOptionsFn)(ProcessSerialNumber *psn, uint32_t wid, uint32_t mode);
typedef CGError (*SLPSPostEventRecordToFn)(ProcessSerialNumber *psn, uint8_t *bytes);

static SLPSSetFrontProcessWithOptionsFn setFrontProcessWithOptions;
static SLPSPostEventRecordToFn postEventRecordTo;

static void resolveSkyLight(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (!handle) return;
        setFrontProcessWithOptions = (SLPSSetFrontProcessWithOptionsFn)dlsym(handle, "_SLPSSetFrontProcessWithOptions");
        postEventRecordTo = (SLPSPostEventRecordToFn)dlsym(handle, "SLPSPostEventRecordTo");
    });
}

bool silk_skylight_focus_available(void) {
    resolveSkyLight();
    return setFrontProcessWithOptions != NULL && postEventRecordTo != NULL;
}

// Event record layout from yabai `window_manager_make_key_window`.
static void makeKeyWindow(ProcessSerialNumber *psn, CGWindowID windowID) {
    uint8_t bytes[0xf8];
    memset(bytes, 0, sizeof(bytes));
    bytes[0x04] = 0xf8;
    bytes[0x3a] = 0x10;
    memcpy(bytes + 0x3c, &windowID, sizeof(windowID));
    memset(bytes + 0x20, 0xff, 0x10);

    bytes[0x08] = 0x01;
    postEventRecordTo(psn, bytes);
    bytes[0x08] = 0x02;
    postEventRecordTo(psn, bytes);
}

bool silk_skylight_focus_window(pid_t pid, CGWindowID windowID) {
    if (!silk_skylight_focus_available()) return false;

    ProcessSerialNumber psn = {0, 0};
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (GetProcessForPID(pid, &psn) != noErr) return false;
#pragma clang diagnostic pop

    const uint32_t kCPSUserGenerated = 0x200;
    if (setFrontProcessWithOptions(&psn, windowID, kCPSUserGenerated) != kCGErrorSuccess) return false;
    makeKeyWindow(&psn, windowID);
    return true;
}
