// Stand-in for LiteX's CPU-specific system.h: Wally's fpgaopensource
// configuration has no caches, so the cache maintenance hooks are empty.
#ifndef DDRINIT_SYSTEM_H
#define DDRINIT_SYSTEM_H

#include <stddef.h>

#define CONFIG_CPU_NOP "nop"

static inline void flush_cpu_icache(void) {}
static inline void flush_cpu_dcache(void) {}
static inline void flush_l2_cache(void) {}
static inline void flush_cpu_dcache_range(void *start, size_t size) { (void)start; (void)size; }
static inline void invd_cpu_dcache_range(void *start, size_t size) { (void)start; (void)size; }
static inline void clean_cpu_dcache_range(void *start, size_t size) { (void)start; (void)size; }

#endif
