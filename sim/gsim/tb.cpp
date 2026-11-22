///////////////////////////////////////////
// tb.cpp
//
// Purpose: C++ harness for gsimtop (sim/gsim/gsimtop.sv), built either on the gsim model (-DGSIM) or on a Verilator
//          model of the same top, so that the two simulators run the same design and the same programs.  It loads
//          the ELF's segments into the uncore RAM, holds reset, and runs until the program stores its result to
//          tohost (seen in the Memory stage, as testbench.sv does) or jumps to itself.  1 = pass.
//
// Usage:   tb <elf> [max cycles]
//
// A component of the Wally configurable RISC-V project.
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <elf.h>
#include <string>
#include <type_traits>
#include <vector>

static const uint64_t RAM_BASE = 0x80000000ull;
static const uint64_t RAM_BYTES = 128ull << 20;

// write one byte into a RAM of XLEN-bit words (uint32_t or uint64_t elements)
template <class A> static void put8(A &ram, uint64_t a, uint8_t v) {
  auto &w = ram[a / sizeof(ram[0])];
  using T = std::remove_reference_t<decltype(w)>;
  unsigned sh = 8 * (a % sizeof(T));
  w = (w & ~(T(0xff) << sh)) | (T(v) << sh);
}

#ifdef GSIM
#include "gsimtop.h"
struct Model {
  Sgsimtop *m = new Sgsimtop();
  Model() { m->init(); m->set_HREADYEXT(1); m->set_HRESPEXT(0); m->set_HRDATAEXT(0); m->set_GPIOIN(0);
            m->set_UARTSin(1); m->set_SPIIn(0); m->set_SDCIn(0); }
  void reset(int r) { m->set_reset(r); }
  void tick() { m->step(); }
  void write8(uint64_t a, uint8_t v) { put8(m->dut_uncoregen_uncore_ram_ram_memory_ram_RAM, a, v); }
  uint64_t IEUAdrM() { return m->IEUAdrM; }
  uint64_t WriteDataM() { return m->WriteDataM; }
  uint32_t InstrM() { return m->InstrM; }
  bool retiringM() { return m->InstrValidM && !m->StallM && !m->FlushM; }
};
#else
#include "Vgsimtop.h"
#include "Vgsimtop___024root.h"
#include "verilated.h"
extern "C" const char *getenvval(const char *name) { const char *v = getenv(name); return v ? v : ""; }  // ram1p1rwbe's DPI import
struct Model {
  VerilatedContext *ctx = new VerilatedContext;
  Vgsimtop *m = new Vgsimtop(ctx);
  Model() { m->HREADYEXT = 1; m->HRESPEXT = 0; m->HRDATAEXT = 0; m->GPIOIN = 0; m->UARTSin = 1; m->SPIIn = 0;
            m->SDCIn = 0; m->clock = 0; m->reset = 1; m->eval(); }
  void reset(int r) { m->reset = r; }
  void tick() { m->clock = 1; m->eval(); m->clock = 0; m->eval(); }
  void write8(uint64_t a, uint8_t v) { put8(m->rootp->VGSIM_RAM, a, v); }
  uint64_t IEUAdrM() { return m->IEUAdrM; }
  uint64_t WriteDataM() { return m->WriteDataM; }
  uint32_t InstrM() { return m->InstrM; }
  bool retiringM() { return m->InstrValidM && !m->StallM && !m->FlushM; }
};
#endif

// load the ELF's PT_LOAD segments into the RAM; return the address of tohost (0 if the ELF has none)
template <class Ehdr, class Phdr, class Shdr, class Sym>
static uint64_t load(Model &d, const std::vector<uint8_t> &f) {
  auto *eh = (const Ehdr *)f.data();
  for (int i = 0; i < eh->e_phnum; i++) {
    auto *ph = (const Phdr *)(f.data() + eh->e_phoff + i * eh->e_phentsize);
    if (ph->p_type != PT_LOAD) continue;
    for (uint64_t j = 0; j < ph->p_memsz; j++) {
      uint64_t a = ph->p_paddr + j;
      if (a < RAM_BASE || a >= RAM_BASE + RAM_BYTES) { fprintf(stderr, "segment outside the RAM at %lx\n", a); exit(2); }
      d.write8(a - RAM_BASE, j < ph->p_filesz ? f[ph->p_offset + j] : 0);
    }
  }
  auto *sh = (const Shdr *)(f.data() + eh->e_shoff);
  for (int i = 0; i < eh->e_shnum; i++) {
    if (sh[i].sh_type != SHT_SYMTAB) continue;
    auto *str = (const char *)(f.data() + sh[sh[i].sh_link].sh_offset);
    auto *sym = (const Sym *)(f.data() + sh[i].sh_offset);
    for (uint64_t k = 0; k < sh[i].sh_size / sizeof(Sym); k++)
      if (!strcmp(str + sym[k].st_name, "tohost")) return sym[k].st_value;
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s <elf> [max cycles]\n", argv[0]); return 2; }
  uint64_t maxcycles = argc > 2 ? strtoull(argv[2], 0, 0) : 100000000ull;
  FILE *fp = fopen(argv[1], "rb");
  if (!fp) { perror(argv[1]); return 2; }
  std::vector<uint8_t> f;
  uint8_t buf[65536];
  size_t n;
  while ((n = fread(buf, 1, sizeof buf, fp)) > 0) f.insert(f.end(), buf, buf + n);
  fclose(fp);

  Model d;
  uint64_t tohost = f[EI_CLASS] == ELFCLASS64 ? load<Elf64_Ehdr, Elf64_Phdr, Elf64_Shdr, Elf64_Sym>(d, f)
                                              : load<Elf32_Ehdr, Elf32_Phdr, Elf32_Shdr, Elf32_Sym>(d, f);
  d.reset(1);
  for (int i = 0; i < 10; i++) d.tick();
  d.reset(0);

  auto t0 = std::chrono::steady_clock::now();
  uint64_t cycles = 0, retired = 0, hi = 0;
  int64_t result = -1;
  std::string console;
  bool debug = getenv("TB_DEBUG");
  while (cycles < maxcycles) {
    d.tick();
    cycles++;
    if (!d.retiringM()) continue;
    retired++;
    uint32_t in = d.InstrM();
    if (in == 0x6f) { result = 0; break; }                   // j . : halted without a result
    if ((in & 0x7f) != 0x23) continue;                        // stores only
    uint32_t f3 = (in >> 12) & 7;
    uint64_t a = d.IEUAdrM();
    if (debug && tohost && (a & ~7ull) == tohost)
      fprintf(stderr, "cycle %lu store f3 %u to %lx data %lx\n", cycles, f3, a, (unsigned long)d.WriteDataM());
    if (tohost && f3 == 2 && a == tohost + 4) hi = d.WriteDataM() & 0xffffffffu;
    if (tohost && (f3 == 2 || f3 == 3) && a == tohost) {
      uint64_t w = f3 == 3 ? d.WriteDataM() : (hi << 32) | (d.WriteDataM() & 0xffffffffu);
      if ((w >> 48) == 0x0101) { console += char(w & 0xff); continue; }   // HTIF putchar
      result = w & 0xffffffffu;
      break;
    }
  }
  double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  if (!console.empty()) printf("%s", console.c_str());
  printf("%s: %s  cycles %lu  retired %lu  %.3f s  %.0f cycles/s\n", argv[1],
         result == 1 ? "PASS" : result < 0 ? "TIMEOUT" : "FAIL", cycles, retired, s, cycles / s);
  return result == 1 ? 0 : 1;
}
