/* StudioSync Hop: the local channel between the Hop plug-in and the StudioSync extension (docs/realtime-roadmap.md 4b, "live hops").
   One plain C header both sides include (plugin/HopPlugin.cpp and extension/hop.cpp), so the layout and the name can't drift apart.

   Why shared memory and not a function call: REAPER can run a plug-in in a separate process ("run as separate process" or "dedicated
   process", reaper_host64), where the extension's functions aren't reachable. A named mapping works the same in both cases.
   The name is the hop id plus REAPER's pid (James, rt): two REAPERs on one computer never share a hop. A bridged plug-in finds REAPER's
   pid as its parent's (hop_reaper_pid).

   Layout: two rings of HOP_FRAMES interleaved stereo frames, indexed by an absolute frame number that only grows (masked by HOP_MASK):
     send[]  the plug-in's input. Single writer: the plug-in. It publishes send_w (frames written so far) after each block.
     ret[]   the processed audio. Single writer: the extension. ret frame i is the processed version of send frame i, so timing is carried
             by the index, not by when it arrives. The extension publishes ret_w: every ret[i] with i < ret_w is valid.
   The plug-in outputs ret[i - latency] at frame i. If that frame isn't there yet (i - latency >= ret_w) it plays its own input delayed by
   the same latency (or silence) and counts the block as late, so the timing never shifts.

   The network leg (for extension/rtaudio*, not built here): the requester's extension reads send frames [r, send_w) with hop_copy_out,
   sends them tagged with their frame number, writes what comes back at the same frame numbers with hop_copy_in, and moves ret_w forward
   with hop_store only over a contiguous run (a lost packet is concealed or zeroed first, so ret_w never skips a hole). The frame number is
   the only clock the hop needs: the remote side processes in order and returns the numbers it was given.

   MIDI (rt-hopvst: an instrument you don't have): the plug-in puts the MIDI it gets into send_midi under the frame number it came at and
   publishes send_mw before send_w, so every event below send_w is there once send_w is; the network leg sends them with the audio, and at
   the remote end writes them into Hop X's ret_midi under X's frame numbers (publishing ret_mw after). X plays each event with the ret[]
   frame of the same number, so the instrument after X is driven exactly where the audio would be, and comes back under the same numbers.
   dry_lost: what a frame the network lost plays (the network leg fills it in from send[]): the plug-in's "Dry when late".

   Lock-free: one writer per field; plain 64-bit counters read and written through hop_load / hop_store (acquire / release).
   Trust: anything in the mapping can be scribbled on by another process of the same user, so every index is masked before use.
   GPL-3.0-or-later. */
#ifndef STUDIOSYNC_HOP_SHM_H
#define STUDIOSYNC_HOP_SHM_H

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <tlhelp32.h>
#include <intrin.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <strings.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

#define HOP_SHM_MAGIC 0x31504F48u /* "HOP1" */
#define HOP_SHM_VERSION 2u        /* 2: dry_lost and the MIDI rings (rt-hopvst); a v1 plug-in and a v2 extension don't pair: they ship together */
#define HOP_CH 2                  /* stereo: a mono track reaches a plug-in as two channels in REAPER */
#define HOP_FRAMES (1u << 17)     /* about 2.7 s at 48 kHz: far more than the largest latency (8192) plus a block */
#define HOP_MASK (HOP_FRAMES - 1u)
#define HOP_MIDI 4096u            /* MIDI events in each MIDI ring (a power of two) */
#define HOP_LAT_MAX 32768u        /* the most latency a Hop reports: 680 ms at 48 kHz, for long links (rt-hopvst; was 8192) */

enum { HOP_EXT_NONE = 0, HOP_EXT_LOOPBACK = 1, HOP_EXT_NETWORK = 2 };

/* One MIDI event: a short message (status, data 1, data 2 in msg's low bytes; len 1-3) at an absolute frame number. */
typedef struct hop_midi { uint64_t frame; uint32_t msg, len; } hop_midi;

typedef struct hop_shm {
  uint32_t magic, version, channels, frames; /* set once by whoever made the mapping; magic last, so a half-made one reads as not ready */
  double srate;                              /* plug-in: its sample rate */
  uint64_t latency;                          /* plug-in: the latency it reports to the host, in frames */
  uint64_t send_w;                           /* plug-in: send frames written so far */
  uint64_t ret_w;                            /* extension: ret[i] is valid for every i < ret_w */
  uint64_t late;                             /* plug-in: blocks where the return wasn't there in time */
  uint64_t blocks;                           /* plug-in: blocks processed (it's alive while this moves) */
  uint32_t ext_mode, ext_delay;              /* extension: HOP_EXT_*, and the loopback's delay in frames */
  uint64_t dry_lost;                         /* plug-in: 1 when a frame the network lost plays the dry input ("Dry when late"), 0 silence */
  uint64_t send_mw;                          /* plug-in: MIDI events written into send_midi so far */
  uint64_t ret_mw;                           /* extension: MIDI events written into ret_midi so far */
  uint64_t reserved[5];
  float send[HOP_FRAMES * HOP_CH];
  float ret[HOP_FRAMES * HOP_CH];
  hop_midi send_midi[HOP_MIDI];              /* plug-in: the MIDI it was given, at send frame numbers, in order; event k at [k % HOP_MIDI] */
  hop_midi ret_midi[HOP_MIDI];               /* extension: MIDI for the plug-in to play, at ret frame numbers (with ret[] of that frame) */
} hop_shm;

static inline uint64_t hop_load(const uint64_t *p)
{
#ifdef _MSC_VER
  return (uint64_t)_InterlockedCompareExchange64((volatile long long *)p, 0, 0); /* (a full barrier; a few per block, so cheap) */
#else
  return __atomic_load_n(p, __ATOMIC_ACQUIRE);
#endif
}
static inline void hop_store(uint64_t *p, uint64_t v)
{
#ifdef _MSC_VER
  _InterlockedExchange64((volatile long long *)p, (long long)v);
#else
  __atomic_store_n(p, v, __ATOMIC_RELEASE);
#endif
}

static inline int hop_shm_ok(const hop_shm *s)
{
  return s && s->magic == HOP_SHM_MAGIC && s->version == HOP_SHM_VERSION && s->channels == HOP_CH && s->frames == HOP_FRAMES;
}

/* n frames between a ring and a plain interleaved buffer, starting at absolute frame `at` (wraps at the ring's end). */
static inline void hop_copy_in(float *ring, uint64_t at, const float *src, uint32_t n)
{
  while (n) {
    uint32_t pos = (uint32_t)(at & HOP_MASK), run = HOP_FRAMES - pos < n ? HOP_FRAMES - pos : n;
    memcpy(ring + (size_t)pos * HOP_CH, src, (size_t)run * HOP_CH * sizeof(float));
    at += run; src += (size_t)run * HOP_CH; n -= run;
  }
}
static inline void hop_copy_out(const float *ring, uint64_t at, uint32_t n, float *dst)
{
  while (n) {
    uint32_t pos = (uint32_t)(at & HOP_MASK), run = HOP_FRAMES - pos < n ? HOP_FRAMES - pos : n;
    memcpy(dst, ring + (size_t)pos * HOP_CH, (size_t)run * HOP_CH * sizeof(float));
    at += run; dst += (size_t)run * HOP_CH; n -= run;
  }
}

/* REAPER's pid: our own, unless we're in REAPER's plug-in bridge (reaper_host64 and the like), whose parent is REAPER. */
static inline unsigned long hop_reaper_pid(void)
{
#ifdef _WIN32
  char path[MAX_PATH] = "";
  GetModuleFileNameA(NULL, path, MAX_PATH);
  const char *base = strrchr(path, '\\') ? strrchr(path, '\\') + 1 : path;
  DWORD me = GetCurrentProcessId();
  if (_strnicmp(base, "reaper_host", 11) != 0) return me;
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  PROCESSENTRY32 pe;
  pe.dwSize = sizeof(pe);
  DWORD parent = me;
  if (snap != INVALID_HANDLE_VALUE) {
    for (BOOL ok = Process32First(snap, &pe); ok; ok = Process32Next(snap, &pe))
      if (pe.th32ProcessID == me) { parent = pe.th32ParentProcessID; break; }
    CloseHandle(snap);
  }
  return parent;
#else
  char base[64] = "";
#ifdef __APPLE__
  snprintf(base, sizeof(base), "%s", getprogname() ? getprogname() : "");
#else
  FILE *f = fopen("/proc/self/comm", "r");
  if (f) { if (!fgets(base, sizeof(base), f)) base[0] = 0; fclose(f); }
#endif
  return strncasecmp(base, "reaper_host", 11) == 0 ? (unsigned long)getppid() : (unsigned long)getpid();
#endif
}

/* The mapping's name. macOS allows 31 characters for a shm name, so it stays short. */
static inline void hop_shm_name(char *out, size_t n, unsigned long pid, int hop_id)
{
#ifdef _WIN32
  snprintf(out, n, "Local\\StudioSyncHop-%lu-%d", pid, hop_id);
#else
  snprintf(out, n, "/sshop-%lu-%d", pid, hop_id);
#endif
}

typedef struct hop_map {
  hop_shm *p;
#ifdef _WIN32
  HANDLE h;
#endif
  char name[64];
} hop_map;

/* Open the hop's mapping, making it if it isn't there yet (whichever side comes first). Returns the mapping, or NULL. */
static inline hop_shm *hop_shm_open(hop_map *m, unsigned long pid, int hop_id)
{
  int made = 0;
  memset(m, 0, sizeof(*m));
  hop_shm_name(m->name, sizeof(m->name), pid, hop_id);
#ifdef _WIN32
  unsigned long long size = sizeof(hop_shm);
  m->h = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, (DWORD)(size >> 32), (DWORD)size, m->name);
  if (!m->h) return NULL;
  made = GetLastError() != ERROR_ALREADY_EXISTS; /* (a new mapping comes zeroed) */
  m->p = (hop_shm *)MapViewOfFile(m->h, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(hop_shm));
  if (!m->p) { CloseHandle(m->h); m->h = NULL; return NULL; }
#else
  int fd = shm_open(m->name, O_RDWR | O_CREAT | O_EXCL, 0600);
  if (fd >= 0) {
    made = 1;
    if (ftruncate(fd, (off_t)sizeof(hop_shm)) != 0) { close(fd); shm_unlink(m->name); return NULL; } /* (zero-filled) */
  } else {
    if (errno != EEXIST || (fd = shm_open(m->name, O_RDWR, 0600)) < 0) return NULL;
    struct stat st;
    if (fstat(fd, &st) != 0 || (size_t)st.st_size < sizeof(hop_shm)) { close(fd); return NULL; } /* (the maker hasn't sized it yet) */
  }
  void *p = mmap(NULL, sizeof(hop_shm), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  close(fd);
  if (p == MAP_FAILED) return NULL;
  m->p = (hop_shm *)p;
#endif
  if (made) {
    m->p->version = HOP_SHM_VERSION; m->p->channels = HOP_CH; m->p->frames = HOP_FRAMES;
#ifdef _MSC_VER
    MemoryBarrier();
#else
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
#endif
    m->p->magic = HOP_SHM_MAGIC;
  }
  return m->p;
}

static inline void hop_shm_close(hop_map *m)
{
#ifdef _WIN32
  if (m->p) UnmapViewOfFile(m->p);
  if (m->h) CloseHandle(m->h);
  m->h = NULL;
#else
  if (m->p) munmap(m->p, sizeof(hop_shm));
#endif
  m->p = NULL;
}

/* POSIX names outlive their processes; the extension takes its hops' names away when REAPER quits (open mappings stay valid). */
static inline void hop_shm_unlink(const hop_map *m)
{
#ifndef _WIN32
  if (m->name[0]) shm_unlink(m->name);
#else
  (void)m;
#endif
}

#endif
