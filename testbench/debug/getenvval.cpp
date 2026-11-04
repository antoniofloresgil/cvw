// getenvval for the DPI import of Wally's RAMs (as sim/verilator/wrapper.c, for debug_tb)
#include <cstdlib>

extern "C" const char *getenvval(const char *pszName) {
    const char *pszValue = std::getenv(pszName);
    return pszValue == nullptr ? "" : pszValue;
}
