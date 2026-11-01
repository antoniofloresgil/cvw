// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
/* Branch-heavy userspace workload for PMU counting and sampling checks. */
#include <stdint.h>
#include <stdlib.h>

static volatile uint64_t data[64];

int main(int argc, char **argv) {
    unsigned long rounds = argc > 1 ? strtoul(argv[1], NULL, 0) : 60000;
    uint64_t value = 0;
    for (unsigned long i = 0; i < rounds; ++i) {
        unsigned slot = (unsigned)((i * 17) & 63);
        if (data[slot] & 1)
            value += i ^ data[slot];
        else
            value ^= i + data[slot];
        data[slot] = value;
    }
    return value == UINT64_MAX;
}
