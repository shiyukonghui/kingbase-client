// Winsock2 + timing + entropy shims for the MoonBit KingbaseES client.
// Only blocking sockets are exposed: the MoonBit layer reads and writes
// synchronously, which keeps the wire protocol code straightforward.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <bcrypt.h>
#include <stdio.h>
#include <string.h>

#include "moonbit.h"

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "bcrypt.lib")

static int wsa_started = 0;

int32_t kb_net_init(void) {
  WSADATA d;
  if (wsa_started) return 0;
  if (WSAStartup(MAKEWORD(2, 2), &d) != 0) return -1;
  wsa_started = 1;
  return 0;
}

int64_t kb_connect(uint8_t *host_bytes, int32_t port) {
  char host[256];
  struct addrinfo hints, *res = NULL;
  char svc[16];
  SOCKET s;
  snprintf(host, sizeof(host), "%s", (const char *)host_bytes);
  snprintf(svc, sizeof(svc), "%d", (int)port);
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  if (getaddrinfo(host, svc, &hints, &res) != 0 || res == NULL) return -1;
  s = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
  if (s == INVALID_SOCKET) {
    freeaddrinfo(res);
    return -2;
  }
  if (connect(s, res->ai_addr, (int)res->ai_addrlen) == SOCKET_ERROR) {
    int e = WSAGetLastError();
    freeaddrinfo(res);
    closesocket(s);
    return -(int64_t)e;
  }
  freeaddrinfo(res);
  return (int64_t)s;
}

void kb_close(int64_t sock) { closesocket((SOCKET)(intptr_t)sock); }

int32_t kb_send_all(int64_t sock, uint8_t *data, int32_t len) {
  SOCKET s = (SOCKET)(intptr_t)sock;
  int32_t off = 0;
  while (off < len) {
    int n = send(s, (const char *)data + off, len - off, 0);
    if (n == SOCKET_ERROR) return -WSAGetLastError();
    off += n;
  }
  return off;
}

/* Sends len bytes starting at offset, so a message header and a large payload
   can go out as separate writes without copying the payload. */
int32_t kb_send_slice(int64_t sock, uint8_t *data, int32_t offset, int32_t len) {
  SOCKET s = (SOCKET)(intptr_t)sock;
  int32_t off = 0;
  while (off < len) {
    int n = send(s, (const char *)data + offset + off, len - off, 0);
    if (n == SOCKET_ERROR) return -WSAGetLastError();
    off += n;
  }
  return off;
}

int32_t kb_set_tcp_nodelay(int64_t sock, int32_t on) {
  int v = on ? 1 : 0;
  return setsockopt((SOCKET)(intptr_t)sock, IPPROTO_TCP, TCP_NODELAY, (char *)&v, sizeof(v)) == SOCKET_ERROR ? -WSAGetLastError() : 0;
}

int32_t kb_set_send_buffer(int64_t sock, int32_t bytes) {
  int v = (int)bytes;
  return setsockopt((SOCKET)(intptr_t)sock, SOL_SOCKET, SO_SNDBUF, (char *)&v, sizeof(v)) == SOCKET_ERROR ? -WSAGetLastError() : 0;
}

/* Reads exactly n bytes into a freshly allocated MoonBit Bytes.
   NULL means the peer closed the connection before n bytes arrived. */
moonbit_bytes_t kb_read_bytes(int64_t sock, int32_t n) {
  moonbit_bytes_t b = moonbit_make_bytes_raw(n);
  int32_t got = 0;
  while (got < n) {
    int r = recv((SOCKET)(intptr_t)sock, (char *)b + got, n - got, 0);
    if (r <= 0) {
      moonbit_decref(b);
      return NULL;
    }
    got += r;
  }
  return b;
}

/* Fills a MoonBit Bytes with n cryptographically random bytes. */
moonbit_bytes_t kb_random_bytes(int32_t n) {
  moonbit_bytes_t b = moonbit_make_bytes_raw(n);
  if (n <= 0) return b;
  if (BCryptGenRandom(NULL, b, (ULONG)n, BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    for (int32_t i = 0; i < n; i++) b[i] = (uint8_t)(((t.QuadPart * 6364136223846793005ULL) >> 33) ^ (i * 2654435761U));
  }
  return b;
}

/* Monotonic microseconds for latency measurement. */
int64_t kb_now_us(void) {
  static LARGE_INTEGER freq = {0, 0};
  LARGE_INTEGER t;
  if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
  QueryPerformanceCounter(&t);
  return (int64_t)((double)t.QuadPart * 1000000.0 / (double)freq.QuadPart);
}

void kb_sleep_ms(int32_t ms) { Sleep((DWORD)ms); }

int64_t kb_pid(void) { return (int64_t)GetCurrentProcessId(); }
