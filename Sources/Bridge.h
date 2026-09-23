// The C pieces Swift needs: libproc for the process table, and the SMC reader.
#include <libproc.h>
#include <sys/proc_info.h>
#include "smc.h"
