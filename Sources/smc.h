// Read-only access to the System Management Controller: fan speeds and temperature sensors.
// The same interface smcFanControl and iStat Menus read. MacSense never writes to the SMC.
#ifndef MACSENSE_SMC_H
#define MACSENSE_SMC_H

#include <stdbool.h>

bool ms_smc_open(void);
void ms_smc_close(void);

/// Reads a four-character key ("F0Ac", "TC0P", ...) and decodes it to a number.
/// Returns false when this Mac doesn't have the key or its type isn't numeric.
bool ms_smc_read(const char *key, double *value);

#endif
