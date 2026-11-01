// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include <cstdlib>

// The generic RAM imports this even when FPGA preload is disabled.
extern "C" const char* getenvval(const char* name) {
    const char* value = std::getenv(name);
    return value ? value : "";
}
