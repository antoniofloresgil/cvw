// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include "Vlinux_tb.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
static void dump(const QData &value) {
    std::fprintf(stderr, " %016llx", (unsigned long long)value);
}
template<std::size_t Words> static void dump(const VlWide<Words> &value) {
    for (std::size_t h = 0; h < Words / 2; ++h)
        std::fprintf(stderr, " %08x%08x", value[2*h+1], value[2*h]);
}
int main(int argc, char **argv) {
    auto context = std::make_unique<VerilatedContext>();
    context->commandArgs(argc, argv);
    auto top = std::make_unique<Vlinux_tb>(context.get());
    uint64_t limit = 1000000000ULL;
    for (int i = 1; i < argc; ++i)
        if (std::string(argv[i]).rfind("+cycles=", 0) == 0) limit = std::strtoull(argv[i]+8, nullptr, 0);
    std::string line;
    uint64_t nextHeartbeat = 1000000;
    for (uint64_t cycle = 0; cycle < limit && !context->gotFinish(); ++cycle) {
        top->reset_ext = cycle < 10;
        top->clk = 0;
        top->eval();
        const bool consoleValid = top->ConsoleValid;
        const char c = top->ConsoleData;
        top->clk = 1;
        top->eval();
        std::fflush(stdout);
        context->timeInc(1);
        if (consoleValid) {
            // uartPC16550D already prints each THR write with $write.
            // Observe the same transfer here only to recognize the verdict.
            if (c == '\n') {
                if (line.find("WALLY_SMP_FAIL") != std::string::npos) {
                    top->final();
                    return 1;
                }
                if (line.find("WALLY_SMP_PASS") != std::string::npos) {
                    std::fprintf(stderr, "PASS: Linux SMP on Wally RTL after %llu cycles\n", (unsigned long long)cycle);
                    top->final();
                    return 0;
                }
                line.clear();
            } else if (c != '\r') line += c;
        }
        if (cycle >= nextHeartbeat && line.empty()) {
            nextHeartbeat = (cycle / 1000000 + 1) * 1000000;
            std::fprintf(stderr, "[RTL cycle %llu PC", (unsigned long long)cycle);
            dump(top->PCs);
            std::fprintf(stderr, " mcause");
            dump(top->Causes);
            std::fprintf(stderr, "]\n");
        }
    }
    std::fprintf(stderr, "FAIL: Linux RTL timeout\n");
    top->final();
    return 1;
}
