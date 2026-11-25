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

// MARK: Multitouch

typedef struct { float x, y; } SilkMTPoint;
typedef struct { SilkMTPoint position, velocity; } SilkMTVector;
// MultitouchSupport's per-finger record (96 bytes), as used by every open-source gesture tool.
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier;
    int32_t state; // 3 = touch begins, 4 = touching; other values hover or lift
    int32_t fingerID;
    int32_t handID;
    SilkMTVector normalized;
    float size;
    int32_t zero1;
    float angle, majorAxis, minorAxis;
    SilkMTVector mm;
    int32_t zero2[2];
    float density;
} SilkMTTouch;

typedef void *SilkMTDeviceRef;
typedef int (*SilkMTContactCallback)(SilkMTDeviceRef, SilkMTTouch *, int, double, int);

static CFArrayRef (*mt_create_list)(void);
static void (*mt_register)(SilkMTDeviceRef, SilkMTContactCallback);
static void (*mt_unregister)(SilkMTDeviceRef, SilkMTContactCallback);
static void (*mt_start)(SilkMTDeviceRef, int);
static void (*mt_stop)(SilkMTDeviceRef);
static CFArrayRef mt_devices;
static silk_touch_callback mt_callback;

static int silk_contact_frame(SilkMTDeviceRef device, SilkMTTouch *touches, int count, double timestamp, int frame) {
    int fingers = 0;
    float x = 0, y = 0;
    for (int i = 0; i < count; i++) {
        if (touches[i].state != 3 && touches[i].state != 4) continue;
        fingers++;
        x += touches[i].normalized.position.x;
        y += touches[i].normalized.position.y;
    }
    silk_touch_callback callback = mt_callback;
    if (callback) callback(fingers, fingers ? x / fingers : 0, fingers ? y / fingers : 0);
    return 0;
}

static bool silk_multitouch_resolve(void) {
    static bool resolved, available;
    if (resolved) return available;
    resolved = true;
    void *handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY);
    if (!handle) return false;
    mt_create_list = dlsym(handle, "MTDeviceCreateList");
    mt_register = dlsym(handle, "MTRegisterContactFrameCallback");
    mt_unregister = dlsym(handle, "MTUnregisterContactFrameCallback");
    mt_start = dlsym(handle, "MTDeviceStart");
    mt_stop = dlsym(handle, "MTDeviceStop");
    available = mt_create_list && mt_register && mt_unregister && mt_start && mt_stop;
    return available;
}

bool silk_multitouch_start(silk_touch_callback callback) {
    silk_multitouch_stop();
    if (!silk_multitouch_resolve()) return false;
    CFArrayRef devices = mt_create_list();
    if (!devices) return false;
    if (CFArrayGetCount(devices) == 0) {
        CFRelease(devices);
        return false;
    }
    mt_callback = callback;
    mt_devices = devices;
    for (CFIndex i = 0; i < CFArrayGetCount(devices); i++) {
        SilkMTDeviceRef device = (SilkMTDeviceRef)CFArrayGetValueAtIndex(devices, i);
        mt_register(device, silk_contact_frame);
        mt_start(device, 0);
    }
    return true;
}

void silk_multitouch_stop(void) {
    if (!mt_devices) return;
    for (CFIndex i = 0; i < CFArrayGetCount(mt_devices); i++) {
        SilkMTDeviceRef device = (SilkMTDeviceRef)CFArrayGetValueAtIndex(mt_devices, i);
        mt_unregister(device, silk_contact_frame);
        mt_stop(device);
    }
    mt_callback = NULL;
    CFRelease(mt_devices);
    mt_devices = NULL;
}
