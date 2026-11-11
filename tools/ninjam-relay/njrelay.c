/* njrelay: a local relay between ReaNINJAM and a NINJAM server, for macOS (StudioSync, GPL-3.0-or-later).
 *
 * Why: when a server simply goes away, ReaNINJAM shows "Disconnected from host!" (its winclient.cpp, whenever a connection
 * ends after sign-in with no error text), and on a Mac that alert holds every script in REAPER, StudioSync's too, until
 * someone presses OK. A disconnect asked for shows none. So ReaNINJAM connects here instead; if the server goes, this keeps
 * ReaNINJAM's connection open, sends it NINJAM's own keepalive (ReaNINJAM drops a connection that's silent for three
 * keepalive periods: netmsg.cpp) and writes "lost" to the status file. StudioSync sees that and presses Disconnect.
 *
 * usage: njrelay <listen port> <target file> <status file> [REAPER's pid]
 * The target file holds the server as "host:port" and is read at each new connection, so the server can move without
 * restarting this (which would drop ReaNINJAM's connection and bring up the very alert this is for). Listens on 127.0.0.1 only. One client at a time. Server-to-client traffic goes on whole messages only (1 byte type,
 * 4 bytes little-endian size, then the body), so a keepalive is never put into the middle of one. Status file: "connecting",
 * "ok", "lost", or "idle" (no client). Exits once REAPER (the pid given) is gone, or on SIGTERM.
 */
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define MSG_KEEPALIVE 0xFD
#define MAX_MSG (64 * 1024 * 1024) /* (an interval of uncompressed audio is far below this; anything bigger is garbage) */

static const char *status_path;
static pid_t reaper_pid; /* 0: run until stopped */
static int reaper_gone(void) { return reaper_pid > 0 && kill(reaper_pid, 0) != 0 && errno == ESRCH; }

static void status(const char *s) {
  char tmp[4096];
  snprintf(tmp, sizeof tmp, "%s.tmp", status_path);
  FILE *f = fopen(tmp, "w");
  if (!f) return;
  fprintf(f, "%s %ld\n", s, (long)time(NULL));
  fclose(f);
  rename(tmp, status_path);
}

static int send_all(int fd, const unsigned char *p, size_t n) {
  while (n > 0) {
    ssize_t w = send(fd, p, n, 0);
    if (w < 0) { if (errno == EINTR) continue; return -1; }
    p += w; n -= (size_t)w;
  }
  return 0;
}

static int dial(const char *host, const char *port) {
  struct addrinfo hints, *res, *a;
  memset(&hints, 0, sizeof hints);
  hints.ai_socktype = SOCK_STREAM;
  if (getaddrinfo(host, port, &hints, &res) != 0) return -1;
  int fd = -1;
  for (a = res; a; a = a->ai_next) {
    fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
    if (fd < 0) continue;
    if (connect(fd, a->ai_addr, a->ai_addrlen) == 0) break;
    close(fd); fd = -1;
  }
  freeaddrinfo(res);
  if (fd >= 0) { int one = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one); }
  return fd;
}

/* "host:port" from the target file (the last colon splits them: no IPv6 literals). -> 0, or -1 */
static int read_target(const char *path, char *host, size_t hn, char *port, size_t pn) {
  char line[512] = "";
  FILE *f = fopen(path, "r");
  if (!f) return -1;
  if (!fgets(line, sizeof line, f)) line[0] = 0;
  fclose(f);
  line[strcspn(line, "\r\n \t")] = 0;
  char *c = strrchr(line, ':');
  if (!c || c == line || !c[1]) return -1;
  *c = 0;
  snprintf(host, hn, "%s", line);
  snprintf(port, pn, "%s", c + 1);
  return 0;
}

/* One client, start to finish. */
static void serve(int cl, const char *target_path) {
  int one = 1;
  setsockopt(cl, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  status("connecting");
  char host[256], port[16];
  int up = read_target(target_path, host, sizeof host, port, sizeof port) == 0 ? dial(host, port) : -1;
  if (up < 0) status("lost"); else status("ok");
  unsigned char *buf = malloc(1 << 16);
  size_t cap = 1 << 16, have = 0; /* server bytes not yet forwarded: always the start of a message */
  time_t last_keep = time(NULL);
  for (;;) {
    if (reaper_gone()) break;
    struct pollfd p[2] = { { cl, POLLIN, 0 }, { up, POLLIN, 0 } };
    int n = poll(p, up >= 0 ? 2 : 1, 1000);
    if (n < 0) { if (errno == EINTR) continue; break; }
    if (p[0].revents & (POLLIN | POLLHUP | POLLERR)) { /* client to server: passed on as it comes */
      unsigned char tmp[1 << 16];
      ssize_t r = recv(cl, tmp, sizeof tmp, 0);
      if (r <= 0) break; /* ReaNINJAM disconnected (asked for, or gone): done with this client */
      if (up >= 0 && send_all(up, tmp, (size_t)r) < 0) { close(up); up = -1; status("lost"); }
    }
    if (up >= 0 && (p[1].revents & (POLLIN | POLLHUP | POLLERR))) {
      if (have == cap) { cap *= 2; buf = realloc(buf, cap); }
      ssize_t r = recv(up, buf + have, cap - have, 0);
      if (r <= 0) { close(up); up = -1; status("lost"); }
      else {
        have += (size_t)r;
        size_t done = 0; /* forward every whole message, keep the rest */
        while (have - done >= 5) {
          size_t len = buf[done + 1] | buf[done + 2] << 8 | buf[done + 3] << 16 | (size_t)buf[done + 4] << 24;
          if (len > MAX_MSG) { close(up); up = -1; status("lost"); break; }
          if (have - done < 5 + len) {
            while (cap < 5 + len) { cap *= 2; buf = realloc(buf, cap); }
            break;
          }
          if (send_all(cl, buf + done, 5 + len) < 0) goto out;
          done += 5 + len;
        }
        if (up < 0) have = 0;
        else { memmove(buf, buf + done, have - done); have -= done; }
      }
    }
    if (up < 0 && time(NULL) - last_keep >= 2) { /* server gone: keep ReaNINJAM waiting quietly until it's told to disconnect */
      unsigned char k[5] = { MSG_KEEPALIVE, 0, 0, 0, 0 };
      if (send_all(cl, k, 5) < 0) break;
      last_keep = time(NULL);
    }
  }
out:
  free(buf);
  if (up >= 0) close(up);
  close(cl);
  status("idle");
}

int main(int argc, char **argv) {
  if (argc < 4) { fprintf(stderr, "usage: njrelay <listen port> <target file> <status file> [REAPER's pid]\n"); return 2; }
  status_path = argv[3];
  reaper_pid = argc > 4 ? (pid_t)atoi(argv[4]) : 0;
  signal(SIGPIPE, SIG_IGN);
  int ls = socket(AF_INET, SOCK_STREAM, 0);
  int one = 1;
  setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_port = htons((unsigned short)atoi(argv[1]));
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(ls, (struct sockaddr *)&a, sizeof a) < 0 || listen(ls, 1) < 0) { status("cantlisten"); return 1; }
  status("idle");
  for (;;) {
    if (reaper_gone()) break;
    struct pollfd p ={ ls, POLLIN, 0 };
    if (poll(&p, 1, 1000) <= 0) continue;
    int cl = accept(ls, NULL, NULL);
    if (cl >= 0) serve(cl, argv[2]);
  }
  close(ls);
  return 0;
}
