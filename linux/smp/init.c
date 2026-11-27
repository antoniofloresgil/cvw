// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#define _GNU_SOURCE
#include <errno.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifndef EXPECTED_CPUS
#define EXPECTED_CPUS 2
#endif
struct shared {
    _Atomic unsigned counter;
    atomic_flag lock;
    unsigned protected_counter;
};
static void fail(const char *what) {
    printf("WALLY_SMP_FAIL %s errno=%d\n", what, errno);
    fflush(stdout);
    for (;;) pause();
}
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (mount("proc", "/proc", "proc", 0, NULL) || mount("sysfs", "/sys", "sysfs", 0, NULL)) fail("mount");
    long cpus = sysconf(_SC_NPROCESSORS_ONLN);
    printf("WALLY_SMP_ONLINE cpus=%ld expected=%d\n", cpus, EXPECTED_CPUS);
    if (cpus != EXPECTED_CPUS) fail("online CPUs");
    struct shared *s = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (s == MAP_FAILED) fail("mmap");
    atomic_init(&s->counter, 0);
    atomic_flag_clear(&s->lock);
    for (int cpu = 0; cpu < EXPECTED_CPUS; cpu++) {
        pid_t pid = fork();
        if (pid < 0) fail("fork");
        if (!pid) {
            cpu_set_t set;
            CPU_ZERO(&set);
            CPU_SET(cpu, &set);
            if (sched_setaffinity(0, sizeof(set), &set)) _exit(2);
            for (int i = 0; i < 64; i++) {
                atomic_fetch_add_explicit(&s->counter, 1, memory_order_seq_cst);
                while (atomic_flag_test_and_set_explicit(&s->lock, memory_order_acquire)) {}
                s->protected_counter++;
                atomic_flag_clear_explicit(&s->lock, memory_order_release);
            }
            if (sched_getcpu() != cpu) _exit(3);
            _exit(0);
        }
    }
    for (int cpu = 0; cpu < EXPECTED_CPUS; cpu++) {
        int status;
        if (wait(&status) < 0 || !WIFEXITED(status) || WEXITSTATUS(status)) fail("pinned worker");
    }
    unsigned count = atomic_load(&s->counter);
    if (count != EXPECTED_CPUS * 64 || s->protected_counter != count) fail("shared counters");
#ifdef IPI_LATENCY
    // Cross-CPU wake-up latency: a byte goes back and forth through two pipes between a process pinned to
    // CPU 0 and one pinned to CPU 1; each blocking read sleeps, so every hop is a wake-up of the other CPU.
    {
        int ab[2], ba[2];
        if (pipe(ab) || pipe(ba)) fail("pipe");
        pid_t pid = fork();
        if (pid < 0) fail("fork");
        cpu_set_t set;
        CPU_ZERO(&set);
        CPU_SET(pid ? 0 : 1, &set);
        if (sched_setaffinity(0, sizeof(set), &set)) fail("affinity");
        char c = 0;
        if (!pid) {
            for (int i = 0; i < IPI_LATENCY; i++)
                if (read(ab[0], &c, 1) != 1 || write(ba[1], &c, 1) != 1) _exit(4);
            _exit(0);
        }
        uint64_t worst = 0, total = 0;
        for (int i = 0; i < IPI_LATENCY; i++) {
            struct timespec t0, t1;
            clock_gettime(CLOCK_MONOTONIC, &t0);
            if (write(ab[1], &c, 1) != 1 || read(ba[0], &c, 1) != 1) fail("ping-pong");
            clock_gettime(CLOCK_MONOTONIC, &t1);
            uint64_t ns = (uint64_t)(t1.tv_sec - t0.tv_sec) * 1000000000u + t1.tv_nsec - t0.tv_nsec;
            total += ns;
            if (ns > worst) worst = ns;
        }
        int status;
        if (waitpid(pid, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status)) fail("ping-pong partner");
        printf("WALLY_SMP_IPI rounds=%d mean_us=%llu worst_us=%llu\n", IPI_LATENCY,
               (unsigned long long)(total / IPI_LATENCY / 1000), (unsigned long long)(worst / 1000));
    }
#endif
    printf("WALLY_SMP_PASS cpus=%ld counter=%u protected=%u\n", cpus, count, s->protected_counter);
    for (;;) pause();
}
