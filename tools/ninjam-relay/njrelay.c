/* njrelay: a local relay between ReaNINJAM and a NINJAM server, for macOS (StudioSync, GPL-3.0-or-later).
 *
 * Why: when a server simply goes away, ReaNINJAM shows "Disconnected from host!" (its winclient.cpp, whenever a connection
 * ends after sign-in with no error text), and on a Mac that alert holds every script in REAPER, StudioSync's too, until
 * someone presses OK. A disconnect asked for shows none. So ReaNINJAM connects here instead; if the server goes, this keeps
 * ReaNINJAM's connection open, sends it NINJAM's own keepalive (ReaNINJAM drops a connection that's silent for three
 * keepalive periods: netmsg.cpp) and writes "lost" to the status file. StudioSync sees that and presses Disconnect.
 *
 * usage: njrelay <listen port> <target file> <status file> [REAPER's pid]
 * Status file: "connecting", "waiting" (no server yet, client held), "ok", "lost", "idle up" / "idle down" (no client; whether the
 * server answers), "cantlisten". Each line ends with the time it was written.
 * The target file holds the server as "host:port" and is read at each new connection, so the server can move without
 * restarting this (which would drop ReaNINJAM's connection and bring up the very alert this is for). Listens on 127.0.0.1 only. One client at a time. Server-to-client traffic goes on whole messages only (1 byte type,
 * 4 bytes little-endian size, then the body), so a keepalive is never put into the middle of one. Status file: "connecting",
 * "ok", "lost", or "idle" (no client). Exits once REAPER (the pid given, else any process called REAPER) has been gone a minute, or on SIGTERM.
 */
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
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
static pid_t reaper_pid; /* 0: look for any process called REAPER */
/* Is REAPER still running? Started from a shell script, this has no REAPER parent to watch, and it ran on for good after REAPER quit,
 * checking the server every 5 s (Mac, 0.58.42). So with no pid given it looks REAPER up by name. */
static int reaper_running(void) {
  if (reaper_pid > 0) return !(kill(reaper_pid, 0) != 0 && errno == ESRCH);
  int n = proc_listallpids(NULL, 0);
  if (n <= 0) return 1; /* (can't tell: carry on) */
  pid_t *pids = malloc(sizeof(pid_t) * (size_t)(n + 64));
  if (!pids) return 1;
  n = proc_listallpids(pids, (int)(sizeof(pid_t) * (size_t)(n + 64)));
  int found = 0;
  for (int i = 0; i < n && !found; i++) {
    char name[256];
    if (proc_name(pids[i], name, sizeof name) > 0 && strcmp(name, "REAPER") == 0) found = 1;
  }
  free(pids);
  return found;
}
/* Gone for a minute (two looks 30 s apart: a REAPER restart takes a few seconds, and the next Connect starts this again anyway) */
static int reaper_gone(void) {
  static time_t last_look = 0;
  static int missing = 0;
  if (time(NULL) - last_look < 30) return 0;
  last_look = time(NULL);
  missing = reaper_running() ? 0 : missing + 1;
  return missing >= 2;
}

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

/* Connect within `secs` (an offline Tailscale machine never answers a connect at all: it would hold this up for over a minute). -> fd, or -1 */
static int dial(const char *host, const char *port, int secs) {
  struct addrinfo hints, *res, *a;
  memset(&hints, 0, sizeof hints);
  hints.ai_socktype = SOCK_STREAM;
  if (getaddrinfo(host, port, &hints, &res) != 0) return -1;
  int fd = -1;
  for (a = res; a; a = a->ai_next) {
    fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
    if (fd < 0) continue;
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    int r = connect(fd, a->ai_addr, a->ai_addrlen);
    if (r < 0 && errno == EINPROGRESS) {
      struct pollfd p = { fd, POLLOUT, 0 };
      int err = 0;
      socklen_t el = sizeof err;
      r = (poll(&p, 1, secs * 1000) == 1 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el) == 0 && err == 0) ? 0 : -1;
    }
    if (r == 0) { fcntl(fd, F_SETFL, fl); break; }
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

/* One client, start to finish. Before the server's first message (its challenge) ReaNINJAM may be sent nothing: anything else, or the
 * connection closing, is a failed connect to it, with its "can't connect to host!" alert (Mac, 0.58.35). So until then a server that
 * doesn't answer is tried again every 2 s, the client held silently, and "waiting" said; after WAIT_FOR s it's "lost", for StudioSync
 * to disconnect, which shows nothing. ReaNINJAM itself gives up on a first message after about 10 s (seen on the Mac, 0.58.39), so
 * WAIT_FOR leaves StudioSync time to act before that. Once signed in, a server gone is "lost" at once, with keepalives to hold
 * ReaNINJAM until StudioSync disconnects. */
#define WAIT_FOR 5 /* (+ up to 1 s of the idle check holding up accept, + one 1 s dial, + StudioSync's ~1 s look: under 10) */
static void serve(int cl, const char *target_path) {
  int one = 1;
  setsockopt(cl, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  status("connecting");
  char host[256], port[16];
  int up = -1, started = 0; /* started: the server's first message has gone to the client */
  time_t since = time(NULL), last_try = 0;
  unsigned char pend[4096]; /* client bytes while there's no server yet (none expected before the challenge) */
  size_t npend = 0;
  unsigned char *buf = malloc(1 << 16);
  size_t cap = 1 << 16, have = 0; /* server bytes not yet forwarded: always the start of a message */
  time_t last_keep = time(NULL);
  for (;;) {
    if (reaper_gone()) break;
    if (up < 0 && !started && time(NULL) - last_try >= 1) { /* (every second: WAIT_FOR is short) */
      last_try = time(NULL);
      /* (1 s: a computer that's gone from Tailscale never refuses, it just doesn't answer, and 3 s dials put "lost" up to 9 s in, against
       * ReaNINJAM's 10. Pointed out by the Mac's test, 0.58.40) */
      if (read_target(target_path, host, sizeof host, port, sizeof port) == 0) up = dial(host, port, 1);
      if (up >= 0) {
        status("ok");
        if (npend && send_all(up, pend, npend) < 0) { close(up); up = -1; }
        npend = 0;
      } else status(time(NULL) - since < WAIT_FOR ? "waiting" : "lost");
    }
    struct pollfd p[2] = { { cl, POLLIN, 0 }, { up, POLLIN, 0 } };
    int n = poll(p, up >= 0 ? 2 : 1, up < 0 && !started ? 200 : 1000); /* (holding: back to the next dial soon) */
    if (n < 0) { if (errno == EINTR) continue; break; }
    if (p[0].revents & (POLLIN | POLLHUP | POLLERR)) { /* client to server: passed on as it comes */
      unsigned char tmp[1 << 16];
      ssize_t r = recv(cl, tmp, sizeof tmp, 0);
      if (r <= 0) break; /* ReaNINJAM disconnected (asked for, or gone): done with this client */
      if (up >= 0) { if (send_all(up, tmp, (size_t)r) < 0) { close(up); up = -1; status("lost"); } }
      else if (!started && npend + (size_t)r <= sizeof pend) { memcpy(pend + npend, tmp, (size_t)r); npend += (size_t)r; }
    }
    if (up >= 0 && (p[1].revents & (POLLIN | POLLHUP | POLLERR))) {
      if (have == cap) { cap *= 2; buf = realloc(buf, cap); }
      ssize_t r = recv(up, buf + have, cap - have, 0);
      if (r <= 0) { close(up); up = -1; status(started ? "lost" : "waiting"); } /* (before the challenge: tried again, as above) */
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
          started = 1;
        }
        if (up < 0) have = 0;
        else { memmove(buf, buf + done, have - done); have -= done; }
      }
    }
    if (up < 0 && started && time(NULL) - last_keep >= 2) { /* server gone after sign-in: keep ReaNINJAM waiting quietly until it's told to disconnect */
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
  time_t last_probe = 0;
  for (;;) {
    if (reaper_gone()) break;
    /* With nobody connected, whether the server answers, every 5 s: "idle up" / "idle down". StudioSync connects on that, not on a
     * port check of its own, which read a server that had just gone as answering and pressed Connect at nothing (Mac, 0.58.39). */
    if (time(NULL) - last_probe >= 5) {
      last_probe = time(NULL);
      char host[256], port[16];
      int fd = read_target(argv[2], host, sizeof host, port, sizeof port) == 0 ? dial(host, port, 1) : -1; /* (1 s: a client waits on it) */
      if (fd >= 0) close(fd);
      status(fd >= 0 ? "idle up" : "idle down");
    }
    struct pollfd p ={ ls, POLLIN, 0 };
    if (poll(&p, 1, 1000) <= 0) continue;
    int cl = accept(ls, NULL, NULL);
    if (cl >= 0) { serve(cl, argv[2]); last_probe = 0; }
  }
  close(ls);
  return 0;
}
