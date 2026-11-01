// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/perf_event.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
static volatile unsigned long data[1024];
static void fail(const char *where) {
    printf("WALLY_PMU_FAIL %s errno=%d\n", where, errno);
    fflush(stdout);
    for (;;) pause();
}
static void workload(void) {
    for (unsigned i = 0; i < 2048; ++i) data[(i * 17) & 1023] += i;
}
static void counter(const char *name, unsigned type, unsigned long config, int must_count) {
    struct perf_event_attr attr = {0};
    attr.size = sizeof(attr); attr.type = type; attr.config = config; attr.disabled = 1;
    int fd = syscall(__NR_perf_event_open, &attr, 0, -1, -1, 0);
    if (fd < 0) fail(name);
    if (ioctl(fd, PERF_EVENT_IOC_RESET, 0) || ioctl(fd, PERF_EVENT_IOC_ENABLE, 0)) fail("start");
    workload();
    if (ioctl(fd, PERF_EVENT_IOC_DISABLE, 0)) fail("stop");
    uint64_t value = 0, stopped = 0;
    if (read(fd, &value, sizeof(value)) != sizeof(value)) fail("read");
    workload();
    if (read(fd, &stopped, sizeof(stopped)) != sizeof(stopped)) fail("read-disabled");
    if (stopped != value || (must_count && !value)) fail("delta-or-stop");
    printf("WALLY_PMU_COUNTER %s value=%" PRIu64 " stopped=%" PRIu64 "\n", name, value, stopped);
    fflush(stdout); close(fd);
}
int main(void) {
    int c = open("/dev/console", O_RDWR);
    if (c >= 0) { dup2(c, 0); dup2(c, 1); dup2(c, 2); }
    mount("proc", "/proc", "proc", 0, NULL);
    mount("sysfs", "/sys", "sysfs", 0, NULL);
    puts("WALLY_PMU_BEGIN"); fflush(stdout);
    counter("cycles", PERF_TYPE_HARDWARE, PERF_COUNT_HW_CPU_CYCLES, 1);
    counter("instructions", PERF_TYPE_HARDWARE, PERF_COUNT_HW_INSTRUCTIONS, 1);
    counter("branches", PERF_TYPE_HARDWARE, PERF_COUNT_HW_BRANCH_INSTRUCTIONS, 1);
    counter("branch-misses", PERF_TYPE_HARDWARE, PERF_COUNT_HW_BRANCH_MISSES, 0);
    counter("cache-references", PERF_TYPE_HARDWARE, PERF_COUNT_HW_CACHE_REFERENCES, 1);
    counter("cache-misses", PERF_TYPE_HARDWARE, PERF_COUNT_HW_CACHE_MISSES, 0);
    counter("raw-conditional-branches", PERF_TYPE_RAW, 3, 1);
    pid_t child = fork();
    if (child < 0) fail("fork");
    if (!child) {
        execl("/perf", "perf", "stat", "-e", "cycles,instructions,branches,branch-misses,cache-references,cache-misses", "--", "/workload", NULL);
        _exit(127);
    }
    int status;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status)) fail("perf-stat");
    puts("WALLY_PMU_PASS perf_event_open_and_perf_stat"); fflush(stdout);
    for (;;) pause();
}
