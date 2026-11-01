///////////////////////////////////////////
// printf.c
//
// Purpose: Small printf for ddrinit: the conversions LiteX's liblitedram uses
//          (%d %i %u %x %X %p %s %c %%, with '-', '0', width and the l/z
//          length modifiers), written through putchar().
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
///////////////////////////////////////////

#include <stdarg.h>
#include <stdio.h>

static int emit(const char *s, int len, int width, int left, char pad) {
  int n = 0;
  if (!left) for (; width > len; width--, n++) putchar(pad);
  for (int i = 0; i < len; i++, n++) putchar(s[i]);
  if (left) for (; width > len; width--, n++) putchar(' ');
  return n;
}

int vprintf(const char *fmt, va_list ap) {
  int n = 0;
  for (; *fmt; fmt++) {
    if (*fmt != '%') { putchar(*fmt); n++; continue; }
    fmt++;
    int left = 0, width = 0, lng = 0;
    char pad = ' ';
    if (*fmt == '-') { left = 1; fmt++; }
    if (*fmt == '0') { pad = '0'; fmt++; }
    while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
    while (*fmt == 'l' || *fmt == 'z') { lng = 1; fmt++; }
    (void)lng;                       // long and size_t are 32 bits on RV32
    char buf[12];
    int len = 0;
    switch (*fmt) {
      case 'd': case 'i': {
        long v = va_arg(ap, long);
        unsigned long u = v < 0 ? -(unsigned long)v : (unsigned long)v;
        do { buf[sizeof buf - 1 - len++] = '0' + u % 10; u /= 10; } while (u);
        if (v < 0) {
          if (pad == '0' && !left) { putchar('-'); n++; width--; }
          else buf[sizeof buf - 1 - len++] = '-';
        }
        n += emit(buf + sizeof buf - len, len, width, left, pad);
        break;
      }
      case 'u': case 'x': case 'X': case 'p': {
        unsigned long u = va_arg(ap, unsigned long);
        unsigned base = (*fmt == 'u') ? 10 : 16;
        const char *digits = (*fmt == 'X') ? "0123456789ABCDEF" : "0123456789abcdef";
        do { buf[sizeof buf - 1 - len++] = digits[u % base]; u /= base; } while (u);
        if (*fmt == 'p') { putchar('0'); putchar('x'); n += 2; }
        n += emit(buf + sizeof buf - len, len, width, left, pad);
        break;
      }
      case 's': {
        const char *s = va_arg(ap, const char *);
        if (!s) s = "(null)";
        int l = 0;
        while (s[l]) l++;
        n += emit(s, l, width, left, ' ');
        break;
      }
      case 'c': buf[0] = (char)va_arg(ap, int); n += emit(buf, 1, width, left, ' '); break;
      case '%': putchar('%'); n++; break;
      default: putchar('%'); putchar(*fmt); n += 2; break;
    }
  }
  return n;
}

int printf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int n = vprintf(fmt, ap);
  va_end(ap);
  return n;
}

int puts(const char *s) {
  while (*s) putchar(*s++);
  putchar('\n');
  return 0;
}
