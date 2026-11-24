// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
/* The board run of the multicore Nexys Video (config fpganexysvideosmp): one thread pinned to each hart.
 *  1. coherence and atomics: the threads add to one counter with amoadd and to another under an LR/SC spin lock,
 *     and pass a token back and forth through plain loads and stores; every total must be exact;
 *  2. memory throughput: each hart alone, then both at once, reads, writes and copies a buffer far larger than the
 *     caches (DDR3 through the cache-line bursts), in MB/s.  With one hart online only the throughput (the reference).
 * Prints SMPCHECK PASS or SMPCHECK FAIL and exits with 0 or 1.   smpcheck [rounds] [buffer MiB] */
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static unsigned long rounds = 200000;
static size_t bytes = 16 << 20;
static volatile uint64_t amo_counter, lock_counter, token;
static volatile int lock;
static pthread_barrier_t barrier;
static double mbps[2][3];

static void pin(int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (sched_setaffinity(0, sizeof(set), &set)) { perror("sched_setaffinity"); exit(1); }
}

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static void spin_lock(void) {
    while (__atomic_exchange_n(&lock, 1, __ATOMIC_ACQUIRE))
        while (__atomic_load_n(&lock, __ATOMIC_RELAXED)) ;
}
static void spin_unlock(void) { __atomic_store_n(&lock, 0, __ATOMIC_RELEASE); }

/* read, write, copy of a buffer of `bytes`: MB/s of each */
static void throughput(double out[3]) {
    uint64_t *a = malloc(bytes), *b = malloc(bytes);
    size_t n = bytes / 8;
    memset(a, 1, bytes); memset(b, 2, bytes);
    volatile uint64_t sum = 0;
    double t = now();
    for (size_t i = 0; i < n; i++) sum += a[i];
    out[0] = bytes / (now() - t) / 1e6;
    t = now();
    for (size_t i = 0; i < n; i++) a[i] = i;
    __asm__ volatile("" : : "r"(a) : "memory");
    out[1] = bytes / (now() - t) / 1e6;
    t = now();
    memcpy(b, a, bytes);
    __asm__ volatile("" : : "r"(a), "r"(b) : "memory");   /* the copy is used: keep it */
    out[2] = 2.0 * bytes / (now() - t) / 1e6;
    free(a); free(b);
}

static void *worker(void *arg) {
    int me = (int)(intptr_t)arg;
    pin(me);
    pthread_barrier_wait(&barrier);
    for (unsigned long i = 0; i < rounds; i++) {
        __atomic_fetch_add(&amo_counter, 1, __ATOMIC_RELAXED);
        spin_lock();
        lock_counter = lock_counter + 1;
        spin_unlock();
    }
    /* ping-pong: thread 0 waits for even values, thread 1 for odd ones */
    for (unsigned long i = 0; i < rounds / 10; i++) {
        while ((__atomic_load_n(&token, __ATOMIC_ACQUIRE) & 1) != (uint64_t)me) ;
        __atomic_store_n(&token, token + 1, __ATOMIC_RELEASE);
    }
    pthread_barrier_wait(&barrier);
    if (me == 1) throughput(mbps[1]);          /* hart 1 alone */
    pthread_barrier_wait(&barrier);
    if (me == 0) throughput(mbps[0]);          /* hart 0 alone */
    pthread_barrier_wait(&barrier);
    double both[3];
    throughput(both);                          /* both at once */
    printf("SMPCHECK both harts at once, hart %d: read %.1f write %.1f copy %.1f MB/s\n", me, both[0], both[1], both[2]);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc > 1) rounds = strtoul(argv[1], NULL, 0);
    if (argc > 2) bytes = strtoul(argv[2], NULL, 0) << 20;
    long cpus = sysconf(_SC_NPROCESSORS_ONLN);
    printf("SMPCHECK %ld harts online, %lu rounds, %zu MiB buffers\n", cpus, rounds, bytes >> 20);
    if (cpus < 2) {   /* a single-hart board: only the throughput, the reference for the multicore memory system */
        throughput(mbps[0]);
        printf("SMPCHECK one hart: read %.1f write %.1f copy %.1f MB/s\n", mbps[0][0], mbps[0][1], mbps[0][2]);
        return 0;
    }
    pthread_t t[2];
    pthread_barrier_init(&barrier, NULL, 2);
    double t0 = now();
    for (int i = 0; i < 2; i++) pthread_create(&t[i], NULL, worker, (void *)(intptr_t)i);
    for (int i = 0; i < 2; i++) pthread_join(t[i], NULL);
    printf("SMPCHECK amoadd %llu lr/sc lock %llu token %llu (expected %lu, %lu, %lu) in %.1f s\n",
           (unsigned long long)amo_counter, (unsigned long long)lock_counter, (unsigned long long)token,
           2 * rounds, 2 * rounds, 2 * (rounds / 10), now() - t0);
    for (int h = 0; h < 2; h++)
        printf("SMPCHECK hart %d alone: read %.1f write %.1f copy %.1f MB/s\n", h, mbps[h][0], mbps[h][1], mbps[h][2]);
    int ok = amo_counter == 2 * rounds && lock_counter == 2 * rounds && token == 2 * (rounds / 10);
    puts(ok ? "SMPCHECK PASS" : "SMPCHECK FAIL");
    return !ok;
}
