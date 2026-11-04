// OpenOCD remote_bitbang server for a Verilator simulation (DPI).
// openocd_tb.sv calls jtag_rbb_tick() every few clock cycles; it accepts one connection on
// the TCP port given by +RBB_PORT (default 9823; 0 picks a free one, printed as "Listening on
// port N", as riscv-tests/debug expects), then applies one command per call:
//   '0'-'7' set TCK, TMS, TDI (bits 2, 1, 0); 'R' sends TDO as '0' or '1';
//   'r'-'u' resets (ignored: the TAP resets through TMS); 'B'/'b' blink; 'Q' quits.
// Returns 1 when OpenOCD quits or closes the connection.  JTAG_RBB_TRACE=<file> logs the
// commands, with the TDO that each R returns.
#include <arpa/inet.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

static int listenfd = -1, clientfd = -1;
// Verilator copies every output argument back to the simulation: always return all three pins
static unsigned char pins_tck = 0, pins_tms = 1, pins_tdi = 0;

static void rbb_listen(int port) {
  listenfd = socket(AF_INET, SOCK_STREAM, 0);
  int one = 1;
  setsockopt(listenfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = htons(port);
  if (bind(listenfd, (sockaddr *)&addr, sizeof(addr)) < 0 || listen(listenfd, 1) < 0) {
    perror("jtag_rbb: bind/listen");
    exit(1);
  }
  socklen_t len = sizeof(addr);
  getsockname(listenfd, (sockaddr *)&addr, &len);         // the port chosen for port 0
  printf("Listening on port %d\n", ntohs(addr.sin_port));
  fflush(stdout);
}

extern "C" int jtag_rbb_tick(int port, unsigned char *tck, unsigned char *tms, unsigned char *tdi,
                             unsigned char tdo) {
  if (listenfd < 0) rbb_listen(port);
  if (clientfd < 0) {
    clientfd = accept(listenfd, nullptr, nullptr);   // blocks until OpenOCD connects
    int one = 1;
    setsockopt(clientfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    printf("jtag_rbb: OpenOCD connected\n");
    fflush(stdout);
  }
  char c;
  ssize_t n = read(clientfd, &c, 1);                // blocks: the simulation follows OpenOCD
  if (n <= 0) {
    *tck = pins_tck; *tms = pins_tms; *tdi = pins_tdi;
    return 1;
  }
  static FILE *trace = getenv("JTAG_RBB_TRACE") ? fopen(getenv("JTAG_RBB_TRACE"), "w") : nullptr;
  if (trace) fprintf(trace, "%c%s", c, c == 'R' ? (tdo ? "=1 " : "=0 ") : "");
  if (c >= '0' && c <= '7') {
    int v = c - '0';
    pins_tck = (v >> 2) & 1;
    pins_tms = (v >> 1) & 1;
    pins_tdi = v & 1;
  } else if (c == 'R') {
    char r = tdo ? '1' : '0';
    if (write(clientfd, &r, 1) != 1) c = 'Q';
  }
  *tck = pins_tck; *tms = pins_tms; *tdi = pins_tdi;
  return c == 'Q';
}
