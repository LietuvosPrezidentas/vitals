#include "sensors.h"
#include <string.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>

// ---- SMC ----
// Layout of the struct the AppleSMC driver expects (80 bytes).
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo;
    uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32];
} SMCParam;

enum { kSMCHandleYPCEvent = 2, kSMCReadKey = 5, kSMCGetKeyInfo = 9 };

static io_connect_t smc;

static uint32_t fourcc(const char *s) {
    return (uint32_t)s[0] << 24 | (uint32_t)s[1] << 16 | (uint32_t)s[2] << 8 | (uint32_t)s[3];
}

static int smc_call(SMCParam *in, SMCParam *out) {
    size_t size = sizeof(SMCParam);
    if (IOConnectCallStructMethod(smc, kSMCHandleYPCEvent, in, sizeof(SMCParam), out, &size) != KERN_SUCCESS) return -1;
    return out->result == 0 ? 0 : -1;
}

int vt_smc_open(void) {
    if (smc) return 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return -1;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &smc);
    IOObjectRelease(service);
    return kr == KERN_SUCCESS ? 0 : -1;
}

int vt_smc_read(const char *key, double *out) {
    if (!smc || strlen(key) != 4) return -1;
    SMCParam in = {0}, res = {0};
    in.key = fourcc(key);
    in.data8 = kSMCGetKeyInfo;
    if (smc_call(&in, &res)) return -1;
    SMCKeyInfo info = res.keyInfo;

    memset(&in, 0, sizeof in); memset(&res, 0, sizeof res);
    in.key = fourcc(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = kSMCReadKey;
    if (smc_call(&in, &res)) return -1;

    const uint8_t *b = res.bytes;
    switch (info.dataType) {
        case 'flt ': { float f; memcpy(&f, b, 4); *out = f; return 0; }
        case 'ui8 ': case 'flag': *out = b[0]; return 0;
        case 'ui16': *out = (b[0] << 8) | b[1]; return 0;
        case 'ui32': *out = ((uint32_t)b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]; return 0;
        case 'sp78': *out = (int16_t)((b[0] << 8) | b[1]) / 256.0; return 0;
        case 'fpe2': *out = ((b[0] << 8) | b[1]) / 4.0; return 0;
        default: return -1;
    }
}

// ---- HID temperature sensors (private IOKit API, the same one powermetrics-free tools use) ----
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);

enum { kIOHIDEventTypeTemperature = 15 };

enum { MAX_SENSORS = 128 };
static IOHIDEventSystemClientRef hid;
static CFArrayRef services;
static char names[MAX_SENSORS][64];

int vt_hid_open(void) {
    if (services) return 0;
    hid = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!hid) return -1;
    int page = 0xff00, usage = 5;  // Apple vendor page, temperature sensors
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page), u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")}, *vals[] = {p, u};
    CFDictionaryRef match = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(hid, match);
    CFRelease(match); CFRelease(p); CFRelease(u);
    services = IOHIDEventSystemClientCopyServices(hid);
    if (!services) return -1;
    // Names never change, so look them up once: each lookup is a round trip to the sensor driver.
    for (CFIndex i = 0; i < CFArrayGetCount(services) && i < MAX_SENSORS; i++) {
        CFTypeRef name = IOHIDServiceClientCopyProperty((IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i), CFSTR("Product"));
        if (name && CFGetTypeID(name) == CFStringGetTypeID())
            CFStringGetCString(name, names[i], sizeof names[i], kCFStringEncodingUTF8);
        if (name) CFRelease(name);
    }
    return 0;
}

int vt_hid_read(VTReading *out, int max, int chip_only) {
    if (!services) return 0;
    int n = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(services) && i < MAX_SENSORS && n < max; i++) {
        if (chip_only && !strstr(names[i], "tdie")) continue;
        IOHIDServiceClientRef s = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        IOHIDEventRef e = IOHIDServiceClientCopyEvent(s, kIOHIDEventTypeTemperature, 0, 0);
        if (!e) continue;
        memcpy(out[n].name, names[i], sizeof out[n].name);
        out[n].value = IOHIDEventGetFloatValue(e, kIOHIDEventTypeTemperature << 16);
        CFRelease(e);
        n++;
    }
    return n;
}
