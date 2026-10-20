// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include "Vpmu_tb.h"
#include "verilated.h"
#include "verilated_save.h"
#include <csignal>
static volatile std::sig_atomic_t interrupted = 0;
static void requestStop(int) { interrupted = 1; }
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
    auto top = std::make_unique<Vpmu_tb>(context.get());
    uint64_t limit = 1000000000ULL;
    for (int i = 1; i < argc; ++i)
        if (std::string(argv[i]).rfind("+cycles=", 0) == 0) limit = std::strtoull(argv[i]+8, nullptr, 0);
    std::string line;
    uint64_t nextHeartbeat = 1000000;
    uint64_t cycle = 0, interval = 5000000;
    std::string checkpoint, restore;
    for (int i = 1; i < argc; ++i) {
        const std::string arg(argv[i]);
        if (arg.rfind("+checkpoint=", 0) == 0) checkpoint = arg.substr(12);
        if (arg.rfind("+restore=", 0) == 0) restore = arg.substr(9);
        if (arg.rfind("+interval=", 0) == 0) interval = std::strtoull(argv[i]+10, nullptr, 0);
    }
    if (interval == 0) return 2;
    if (!restore.empty()) {
        VerilatedRestore stream;
        stream.open(restore);
        if (!stream.isOpen()) return 2;
        stream >> cycle >> nextHeartbeat >> line;
        stream >> context.get() >> *top;
        stream.close();
        std::fprintf(stderr, "CHECKPOINT: restored at cycle %llu\n", (unsigned long long)cycle);
    }
    auto save = [&](uint64_t nextCycle) {
        if (checkpoint.empty()) return;
        const std::string temporary = checkpoint + ".partial";
        VerilatedSave stream;
        stream.open(temporary);
        if (!stream.isOpen()) { std::perror("checkpoint open"); std::exit(2); }
        stream << nextCycle << nextHeartbeat << line;
        stream << context.get() << *top;
        stream.close();
        if (std::rename(temporary.c_str(), checkpoint.c_str())) { std::perror("checkpoint rename"); std::exit(2); }
        std::fprintf(stderr, "CHECKPOINT: saved at cycle %llu\n", (unsigned long long)nextCycle);
    };
    std::signal(SIGTERM, requestStop);
    std::signal(SIGINT, requestStop);
    for (; cycle < limit && !context->gotFinish(); ++cycle) {
        top->reset_ext = cycle < 10;
        top->clk = 0;
        top->eval();
        const bool consoleValid = top->ConsoleValid;
        const char c = top->ConsoleData;
        top->clk = 1;
        top->eval();
        context->timeInc(1);
        if (consoleValid) {
            std::fflush(stdout);
            // uartPC16550D already prints each THR write with $write.
            // Observe the same transfer here only to recognize the verdict.
            if (c == '\n') {
                if (line.find("WALLY_PMU_FAIL") != std::string::npos ||
                    line.find("Kernel panic - not syncing") != std::string::npos) {
                    top->final();
                    return 1;
                }
                if (line.find("WALLY_PMU_PASS") != std::string::npos) {
                    std::fprintf(stderr, "PASS: Linux PMU on Wally RTL after %llu cycles\n", (unsigned long long)cycle);
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
        if ((cycle + 1) % interval == 0 || interrupted) save(cycle + 1);
        if (interrupted) {
            std::fprintf(stderr, "CHECKPOINT: interrupted after %llu cycles\n", (unsigned long long)(cycle+1));
            top->final();
            return 75;
        }
    }
    std::fprintf(stderr, "INCOMPLETE: Linux RTL cycle limit reached\n");
    save(cycle);
    top->final();
    return 75;
}
