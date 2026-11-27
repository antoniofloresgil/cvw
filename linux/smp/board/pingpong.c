// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Wake-up latency between CPUs, small enough to send to the board over the UART (no C library):
//   pingpong <cpu A> <cpu B> [rounds]
//   pingpong s: cost of an empty loop iteration and of a system call (getppid), in nanoseconds
// A byte goes back and forth through two pipes between a process pinned to CPU A and one pinned to CPU B;
// each blocking read sleeps, so with A != B every hop wakes the other CPU (an IPI), and with A == B every
// hop is a context switch on one CPU (the control). Prints the mean and worst round trip in microseconds.
// Build: riscv64-buildroot-linux-gnu-gcc -O2 -static -nostdlib -fno-builtin -o pingpong pingpong.c
typedef unsigned long u64;
struct ts { long sec, nsec; };

static long sys(long n, long a, long b, long c, long d, long e) {
    register long a7 asm("a7") = n, a0 asm("a0") = a, a1 asm("a1") = b, a2 asm("a2") = c, a3 asm("a3") = d,
                  a4 asm("a4") = e;
    asm volatile("ecall" : "+r"(a0) : "r"(a7), "r"(a1), "r"(a2), "r"(a3), "r"(a4) : "memory");
    return a0;
}
enum { GETPPID = 173, READ = 63, WRITE = 64, EXIT = 93, AFFINITY = 122, CLOCK = 113, PIPE2 = 59, CLONE = 220, WAIT4 = 260 };

static void put(const char *s) { long n = 0; while (s[n]) n++; sys(WRITE, 1, (long)s, n, 0, 0); }
static void putu(u64 v) { char b[24]; int i = 23; b[i] = 0; do b[--i] = '0' + v % 10; while (v /= 10); put(b + i); }
static long num(const char *s) { long v = 0; while (*s >= '0' && *s <= '9') v = 10 * v + *s++ - '0'; return v; }
static void pin(long cpu) { u64 mask = 1ul << cpu; if (sys(AFFINITY, 0, sizeof mask, (long)&mask, 0, 0)) { put("affinity failed\n"); sys(EXIT, 1, 0, 0, 0, 0); } }
static u64 now(void) { struct ts t; sys(CLOCK, 1, (long)&t, 0, 0, 0); return (u64)t.sec * 1000000000ul + t.nsec; }

static int run(long argc, char **argv) {
    if (argc == 2 && argv[1][0] == 's') {
        u64 t0 = now();
        for (volatile long i = 0; i < 1000000; i++) {}
        u64 t1 = now();
        for (long i = 0; i < 10000; i++) sys(GETPPID, 0, 0, 0, 0, 0);
        u64 t2 = now();
        put("SPEED loop_ns "); putu((t1 - t0) / 1000000); put(" syscall_ns "); putu((t2 - t1) / 10000); put("\n");
        return 0;
    }
    if (argc < 3) { put("usage: pingpong <cpu A> <cpu B> [rounds]\n"); return 1; }
    long a = num(argv[1]), b = num(argv[2]), rounds = argc > 3 ? num(argv[3]) : 200;
    int ab[2], ba[2];
    if (sys(PIPE2, (long)ab, 0, 0, 0, 0) || sys(PIPE2, (long)ba, 0, 0, 0, 0)) { put("pipe failed\n"); return 1; }
    long pid = sys(CLONE, 17 /* SIGCHLD */, 0, 0, 0, 0);
    char c = 0;
    if (pid == 0) {
        pin(b);
        for (long i = 0; i < rounds; i++)
            if (sys(READ, ab[0], (long)&c, 1, 0, 0) != 1 || sys(WRITE, ba[1], (long)&c, 1, 0, 0) != 1) return 4;
        return 0;
    }
    pin(a);
    u64 total = 0, worst = 0;
    for (long i = 0; i < rounds; i++) {
        u64 t0 = now();
        if (sys(WRITE, ab[1], (long)&c, 1, 0, 0) != 1 || sys(READ, ba[0], (long)&c, 1, 0, 0) != 1) { put("ping-pong failed\n"); return 1; }
        u64 d = now() - t0;
        total += d;
        if (d > worst) worst = d;
    }
    sys(WAIT4, pid, 0, 0, 0, 0);
    put("PINGPONG cpus "); putu(a); put(" "); putu(b); put(" rounds "); putu(rounds);
    put(" mean_us "); putu(total / rounds / 1000); put(" worst_us "); putu(worst / 1000); put("\n");
    return 0;
}

__attribute__((used)) static void start(long *sp) { sys(EXIT, run(sp[0], (char **)(sp + 1)), 0, 0, 0, 0); }
asm(".globl _start\n_start:\n mv a0, sp\n call start\n");
