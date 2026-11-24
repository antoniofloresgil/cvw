// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
/* Linux/SBI Sscofpmf integration: overflow samples and S/U event filtering.
 * Built as the init of the RTL image by delegation_build.py; with -DWALLY_PMU_BOARD it is an ordinary program for a
 * running system (the board): perf and the workload are PERF_PATH and WORKLOAD_PATH, and it exits with 0 or 1. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/perf_event.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef PERF_PATH
#define PERF_PATH "/perf"
#endif
#ifndef WORKLOAD_PATH
#define WORKLOAD_PATH "/workload"
#endif

static volatile uint64_t data[64];

static void fail(const char *where) {
    printf("WALLY_PMU_FAIL %s errno=%d\n", where, errno);
    fflush(stdout);
#ifdef WALLY_PMU_BOARD
    exit(1);
#endif
    for (;;) pause();
}

static int event_open(struct perf_event_attr *attr) {
    int fd = syscall(__NR_perf_event_open, attr, 0, -1, -1, 0);
    if (fd < 0) fail("perf_event_open");
    return fd;
}

static void work(unsigned long rounds) {
    uint64_t value = 0;
    for (unsigned long i = 0; i < rounds; ++i) {
        unsigned slot = (unsigned)((i * 17) & 63);
        if (data[slot] & 1)
            value += i ^ data[slot];
        else
            value ^= i + data[slot];
        data[slot] = value;
    }
}

static uint64_t filtered_branches(int exclude_kernel, int exclude_user) {
    struct perf_event_attr attr = {0};
    attr.size = sizeof(attr);
    attr.type = PERF_TYPE_HARDWARE;
    attr.config = PERF_COUNT_HW_BRANCH_INSTRUCTIONS;
    attr.disabled = 1;
    attr.exclude_kernel = exclude_kernel;
    attr.exclude_user = exclude_user;
    attr.exclude_hv = 1;
    int fd = event_open(&attr);
    if (ioctl(fd, PERF_EVENT_IOC_RESET, 0) || ioctl(fd, PERF_EVENT_IOC_ENABLE, 0))
        fail("filter-start");
    work(60000);
    if (ioctl(fd, PERF_EVENT_IOC_DISABLE, 0)) fail("filter-stop");
    uint64_t count = 0;
    if (read(fd, &count, sizeof(count)) != sizeof(count)) fail("filter-read");
    close(fd);
    return count;
}

#ifdef WALLY_FIXED_FILTER_CHECK
static int run_perf(char *const argv[]);

static uint64_t filtered_fixed(uint64_t event, int exclude_kernel, int exclude_user) {
    struct perf_event_attr attr = {0};
    attr.size = sizeof(attr);
    attr.type = PERF_TYPE_HARDWARE;
    attr.config = event;
    attr.disabled = 1;
    attr.exclude_kernel = exclude_kernel;
    attr.exclude_user = exclude_user;
    attr.exclude_hv = 1;
    int fd = event_open(&attr);
    if (ioctl(fd, PERF_EVENT_IOC_RESET, 0) || ioctl(fd, PERF_EVENT_IOC_ENABLE, 0))
        fail("fixed-filter-start");
    work(60000);
    if (ioctl(fd, PERF_EVENT_IOC_DISABLE, 0)) fail("fixed-filter-stop");
    uint64_t count = 0;
    if (read(fd, &count, sizeof(count)) != sizeof(count)) fail("fixed-filter-read");
    close(fd);
    return count;
}

static void check_fixed_filters(void) {
    uint64_t cycles_user = filtered_fixed(PERF_COUNT_HW_CPU_CYCLES, 1, 0);
    uint64_t cycles_kernel = filtered_fixed(PERF_COUNT_HW_CPU_CYCLES, 0, 1);
    uint64_t instructions_user = filtered_fixed(PERF_COUNT_HW_INSTRUCTIONS, 1, 0);
    uint64_t instructions_kernel = filtered_fixed(PERF_COUNT_HW_INSTRUCTIONS, 0, 1);
    printf("WALLY_PMU_FIXED_FILTER cycles:u=%" PRIu64 " cycles:k=%" PRIu64
           " instructions:u=%" PRIu64 " instructions:k=%" PRIu64 "\n",
           cycles_user, cycles_kernel, instructions_user, instructions_kernel);
    fflush(stdout);
    if (cycles_kernel == 0 || instructions_kernel == 0 ||
        cycles_user <= 1000 || instructions_user <= 1000 ||
        cycles_user <= cycles_kernel * 4 ||
        instructions_user <= instructions_kernel * 4)
        fail("fixed-mode-filter");

    char *user_args[] = {PERF_PATH, "stat", "-e", "cycles:u,instructions:u",
                         "--", WORKLOAD_PATH, NULL};
    char *kernel_args[] = {PERF_PATH, "stat", "-e", "cycles:k,instructions:k",
                           "--", WORKLOAD_PATH, NULL};
    run_perf(user_args);
    run_perf(kernel_args);
    puts("WALLY_PMU_FIXED_FILTER_PASS cycles_and_instructions");
    fflush(stdout);
}
#endif

static void ring_copy(void *dst, const char *ring, size_t ring_size, uint64_t pos, size_t len) {
    size_t offset = pos % ring_size;
    size_t first = ring_size - offset;
    if (first > len) first = len;
    memcpy(dst, ring + offset, first);
    if (len > first) memcpy((char *)dst + first, ring, len - first);
}

static unsigned direct_samples(void) {
    struct perf_event_attr attr = {0};
    attr.size = sizeof(attr);
    attr.type = PERF_TYPE_HARDWARE;
    attr.config = PERF_COUNT_HW_BRANCH_INSTRUCTIONS;
    attr.sample_period = 1024;
    attr.sample_type = PERF_SAMPLE_IP;
    attr.wakeup_events = 1;
    attr.disabled = 1;
    attr.exclude_kernel = 1;
    attr.exclude_hv = 1;
    int fd = event_open(&attr);
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    size_t ring_size = 8 * page;
    struct perf_event_mmap_page *meta = mmap(NULL, page + ring_size,
                                              PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (meta == MAP_FAILED) fail("sample-mmap");
    if (ioctl(fd, PERF_EVENT_IOC_RESET, 0) || ioctl(fd, PERF_EVENT_IOC_ENABLE, 0))
        fail("sample-start");
    work(120000);
    if (ioctl(fd, PERF_EVENT_IOC_DISABLE, 0)) fail("sample-stop");
    uint64_t head = __atomic_load_n(&meta->data_head, __ATOMIC_ACQUIRE);
    uint64_t pos = meta->data_tail;
    const char *ring = (const char *)meta + meta->data_offset;
    unsigned samples = 0;
    if (meta->data_size != ring_size || head - pos > ring_size)
        fail("sample-ring-overrun");
    while (pos + sizeof(struct perf_event_header) <= head) {
        struct perf_event_header header;
        ring_copy(&header, ring, ring_size, pos, sizeof(header));
        if (header.size < sizeof(header) || pos + header.size > head)
            fail("sample-ring-corrupt");
        if (header.type == PERF_RECORD_SAMPLE) ++samples;
        pos += header.size;
    }
    __atomic_store_n(&meta->data_tail, pos, __ATOMIC_RELEASE);
    munmap(meta, page + ring_size);
    close(fd);
    if (!samples) fail("sample-empty");
    return samples;
}

static int run_perf(char *const argv[]) {
    pid_t child = fork();
    if (child < 0) fail("fork");
    if (child == 0) {
        execv(PERF_PATH, argv);
        _exit(127);
    }
    int status = 0;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status))
        fail("perf-command");
    return status;
}

static unsigned recorded_samples(void) {
    unsigned char header[56];
    int fd = open("/tmp/perf.data", O_RDONLY);
    if (fd < 0 || read(fd, header, sizeof(header)) != sizeof(header))
        fail("record-header");
    if (memcmp(header, "PERFILE2", 8)) fail("record-magic");
    uint64_t data_offset, data_size;
    memcpy(&data_offset, header + 40, sizeof(data_offset));
    memcpy(&data_size, header + 48, sizeof(data_size));
    if (!data_size) fail("record-empty");
    unsigned samples = 0;
    uint64_t pos = 0;
    while (pos + sizeof(struct perf_event_header) <= data_size) {
        struct perf_event_header event;
        if (pread(fd, &event, sizeof(event), data_offset + pos) != sizeof(event))
            fail("record-read");
        if (event.size < sizeof(event) || pos + event.size > data_size)
            fail("record-corrupt");
        if (event.type == PERF_RECORD_SAMPLE) ++samples;
        pos += event.size;
    }
    close(fd);
    if (!samples) fail("record-no-samples");
    return samples;
}

int main(void) {
#ifndef WALLY_PMU_BOARD
    int console = open("/dev/console", O_RDWR);
    if (console >= 0) {
        dup2(console, STDOUT_FILENO);
        dup2(console, STDERR_FILENO);
    }
    if (mount("proc", "/proc", "proc", 0, NULL) ||
        mount("sysfs", "/sys", "sysfs", 0, NULL) ||
        mount("tmpfs", "/tmp", "tmpfs", 0, "size=8m"))
        fail("mount");
#endif
    puts("WALLY_PMU_SAMPLING_BEGIN");
    fflush(stdout);

    uint64_t user = filtered_branches(1, 0);
    uint64_t kernel = filtered_branches(0, 1);
    printf("WALLY_PMU_FILTER user_branches=%" PRIu64 " kernel_branches=%" PRIu64 "\n",
           user, kernel);
    fflush(stdout);
    if (user <= 1000 || user <= kernel * 8) fail("mode-filter");
    puts("WALLY_PMU_FILTER_PASS user_vs_kernel");
    fflush(stdout);

#ifdef WALLY_FIXED_FILTER_CHECK
    check_fixed_filters();
#endif

    unsigned samples = direct_samples();
    printf("WALLY_PMU_SAMPLE samples=%u\n", samples);
    fflush(stdout);

    char *stat_args[] = {PERF_PATH, "stat", "-e", "branches:u,branches:k", "--", WORKLOAD_PATH, NULL};
    run_perf(stat_args);
    char *record_args[] = {PERF_PATH, "record", "-e", "branches:u", "-c", "1024",
                           "-o", "/tmp/perf.data", "--", WORKLOAD_PATH, NULL};
    run_perf(record_args);
    unsigned file_samples = recorded_samples();
    printf("WALLY_PMU_SAMPLING_PASS samples=%u record_samples=%u\n", samples, file_samples);
    puts("WALLY_PMU_PASS sampling_and_filtering");
    fflush(stdout);
#ifdef WALLY_PMU_BOARD
    return 0;
#endif
    for (;;) pause();
}
