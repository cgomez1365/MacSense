#include "smc.h"

#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdint.h>
#include <string.h>

enum {
    kSMCUserClientSelector = 2,   // kSMCHandleYPCEvent
    kSMCCmdReadBytes = 5,
    kSMCCmdReadKeyInfo = 9,
};

// Must match AppleSMC's parameter block byte for byte.
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPowerLimits;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCPowerLimits powerLimits;
    SMCKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t command;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;

_Static_assert(sizeof(SMCParam) == 80, "AppleSMC expects an 80-byte parameter block");

static io_connect_t connection = 0;

bool ms_smc_open(void) {
    if (connection) return true;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return false;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) connection = 0;
    return connection != 0;
}

void ms_smc_close(void) {
    if (connection) IOServiceClose(connection);
    connection = 0;
}

static uint32_t fourcc(const char *key) {
    return (uint32_t)(uint8_t)key[0] << 24 | (uint32_t)(uint8_t)key[1] << 16 |
           (uint32_t)(uint8_t)key[2] << 8 | (uint32_t)(uint8_t)key[3];
}

static bool smc_call(SMCParam *input, SMCParam *output) {
    size_t size = sizeof(SMCParam);
    kern_return_t kr = IOConnectCallStructMethod(connection, kSMCUserClientSelector,
                                                 input, sizeof(SMCParam), output, &size);
    return kr == KERN_SUCCESS && output->result == 0;
}

static int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

bool ms_smc_read(const char *key, double *value) {
    if (!connection || !key || strlen(key) != 4) return false;

    SMCParam input = {0}, output = {0};
    input.key = fourcc(key);
    input.command = kSMCCmdReadKeyInfo;
    if (!smc_call(&input, &output)) return false;

    SMCKeyInfo info = output.keyInfo;
    if (info.dataSize == 0 || info.dataSize > sizeof(output.bytes)) return false;

    memset(&input, 0, sizeof input);
    memset(&output, 0, sizeof output);
    input.key = fourcc(key);
    input.keyInfo.dataSize = info.dataSize;
    input.command = kSMCCmdReadBytes;
    if (!smc_call(&input, &output)) return false;

    const uint8_t *b = output.bytes;
    char type[5] = { (char)(info.dataType >> 24), (char)(info.dataType >> 16),
                     (char)(info.dataType >> 8), (char)info.dataType, 0 };

    if (!strcmp(type, "flt ") && info.dataSize == 4) { float f; memcpy(&f, b, 4); *value = f; return true; }
    if (!strcmp(type, "ui8 ") && info.dataSize == 1) { *value = b[0]; return true; }
    if (!strcmp(type, "ui16") && info.dataSize == 2) { *value = (uint16_t)(b[0] << 8 | b[1]); return true; }
    if (!strcmp(type, "ui32") && info.dataSize == 4) {
        *value = (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 | b[3];
        return true;
    }
    // Fixed point, big-endian: "sp78" is signed with 8 fraction bits, "fpe2" unsigned with 2.
    if ((type[0] == 's' || type[0] == 'f') && type[1] == 'p' && info.dataSize == 2) {
        int fraction = hex_digit(type[3]);
        if (fraction < 0) return false;
        uint16_t raw = (uint16_t)(b[0] << 8 | b[1]);
        double scale = (double)(1 << fraction);
        *value = type[0] == 's' ? (int16_t)raw / scale : raw / scale;
        return true;
    }
    return false;
}
