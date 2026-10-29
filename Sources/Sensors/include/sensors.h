#pragma once
#include <stdint.h>

typedef struct { char name[64]; double value; } VTReading;

// SMC: the Mac's system management controller. Fans, power draw, extra temperatures.
int vt_smc_open(void);                          // 0 on success
int vt_smc_read(const char *key, double *out);  // 0 on success; four-letter key, e.g. "F0Ac"

// Apple silicon's named temperature sensors ("PMU tdie1", "NAND CH0 temp", ...).
int vt_hid_open(void);                          // 0 on success
int vt_hid_read(VTReading *out, int max, int chip_only);  // fills out, returns how many were read;
                                                          // chip_only skips all but the chip's own ("tdie") sensors
