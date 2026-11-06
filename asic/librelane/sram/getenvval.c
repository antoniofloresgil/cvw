// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// getenvval for Wally's generic RAM model, which imports it under Verilator (sim/verilator/wrapper.c needs the testbench)
#include <stdlib.h>

#ifdef __cplusplus
extern "C"
#endif
const char *getenvval(const char *name) {
  const char *value = getenv(name);
  return value ? value : "";
}
