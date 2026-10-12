/* xver — reproduce the two-Go-c-shared-library conflict without the app.
 *
 * The BoltMesh Android app links libwg-go.so (the stock WireGuard plugin) and
 * libawg-go.so (the in-process AWG host) into one process. This loads both and
 * drives their real entry points to show what breaks, and to separate the two
 * distinct failure modes:
 *
 *   xver <libwg> <libawg> same-thread    # one thread enters both: crashes
 *   xver <libwg> <libawg> wg-first       # each runtime on its own thread
 *   xver <libwg> <libawg> awg-first
 *   xver <libwg> <libawg> wg-again       # call libwg again after loading libawg
 *   xver <libwg> <libawg> awg-again
 *   xver <libwg> <libawg> turnon         # control: libwg alone, real TUN
 *   xver <libwg> <libawg> turnon-awg     # the app's descent shape
 *
 * `same-thread` is the inherent one-thread/two-runtimes conflict: both claim the
 * thread's %fs TLS base, so it faults (fault addr 0x38) no matter how symbols
 * are exported. That is why the Java side confines each runtime to its own
 * thread.
 *
 * `turnon-awg` is the app's actual descent: bring a libwg device up and down,
 * then initialize the libawg runtime on another thread, then bring a libwg
 * device up again. It is the test for the process-global half of the problem
 * (signal handlers, altstack, timers) that symbol visibility cannot address.
 *
 * Build with tool/android-debug/build.sh; see README.md for the run.
 */
#include <dlfcn.h>
#include <fcntl.h>
#include <net/if.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#ifndef TUNSETIFF
#define TUNSETIFF _IOW('T', 202, int)
#endif
#ifndef IFF_TUN
#define IFF_TUN 0x0001
#endif
#ifndef IFF_NO_PI
#define IFF_NO_PI 0x1000
#endif

/* 32 zero bytes, base64: enough for the config parser to accept a private key. */
static const char *TURNON_CONFIG =
    "private_key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n"
    "listen_port=51899\n";

typedef const char *(*ver_fn)(void);
typedef int (*turnon_fn)(const char *, int, const char *);
typedef void (*turnoff_fn)(int);

static void *g_wg, *g_awg;
static const char *wg_path, *awg_path;

static void *load(const char *path) {
  printf("loading %s ...\n", path);
  void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
  printf("loading %s -> %p (%s)\n", path, h, h ? "ok" : dlerror());
  return h;
}

static void call(void *h, const char *sym) {
  printf("calling %s ...\n", sym);
  ver_fn f = (ver_fn)dlsym(h, sym);
  if (!f) {
    printf("dlsym %s failed: %s\n", sym, dlerror());
    return;
  }
  const char *v = f();
  printf("%s -> %s\n", sym, v ? v : "(null)");
}

/* A real TUN fd, so wgTurnOn/awgTurnOn get past their fd checks and actually
 * stand the device up (that is where the app's fault happens). */
static int open_tun(const char *name) {
  int fd = open("/dev/net/tun", O_RDWR);
  if (fd < 0) {
    printf("open /dev/net/tun failed\n");
    return -1;
  }
  struct ifreq ifr;
  memset(&ifr, 0, sizeof ifr);
  ifr.ifr_flags = IFF_TUN | IFF_NO_PI;
  strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
  if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
    printf("TUNSETIFF %s failed\n", name);
    close(fd);
    return -1;
  }
  return fd;
}

/* Bring a device up through `h`'s turnOn/turnOff pair, printing the handle. */
static void cycle(void *h, const char *lib, const char *name) {
  char on[32], off[32];
  snprintf(on, sizeof on, "%sTurnOn", lib);
  snprintf(off, sizeof off, "%sTurnOff", lib);
  turnon_fn up = (turnon_fn)dlsym(h, on);
  turnoff_fn down = (turnoff_fn)dlsym(h, off);
  if (!up || !down) {
    printf("dlsym %s/%s failed: %s\n", on, off, dlerror());
    return;
  }
  int fd = open_tun(name);
  if (fd < 0) return;
  printf("calling %s(%s, fd) ...\n", on, name);
  int handle = up(name, fd, TURNON_CONFIG);
  printf("%s -> %d\n", on, handle);
  if (handle >= 0) {
    printf("calling %s(%d) ...\n", off, handle);
    down(handle);
    printf("%s done\n", off);
  }
  close(fd);
}

static void *t_load_wg(void *unused) {
  (void)unused;
  g_wg = load(wg_path);
  call(g_wg, "wgVersion");
  return NULL;
}
static void *t_load_awg(void *unused) {
  (void)unused;
  g_awg = load(awg_path);
  call(g_awg, "awgVersion");
  return NULL;
}
static void *t_wg(void *unused) { (void)unused; call(g_wg, "wgVersion"); return NULL; }
static void *t_awg(void *unused) { (void)unused; call(g_awg, "awgVersion"); return NULL; }

/* Initialize libawg's runtime and stand an AWG device up, off the main thread. */
static void *t_awg_device(void *unused) {
  (void)unused;
  g_awg = load(awg_path);
  if (g_awg) {
    call(g_awg, "awgVersion");
    cycle(g_awg, "awg", "bmhawg0");
  }
  return NULL;
}

static void on_thread(void *(*fn)(void *)) {
  pthread_t t;
  pthread_create(&t, NULL, fn, NULL);
  pthread_join(t, NULL);
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IONBF, 0);
  if (argc < 4) {
    fprintf(stderr, "usage: xver <libwg> <libawg> [same-thread|wg-first|awg-first|wg-again|awg-again|turnon|turnon-awg]\n");
    return 2;
  }
  wg_path = argv[1];
  awg_path = argv[2];
  const char *mode = argv[3];

  if (strcmp(mode, "same-thread") == 0) {
    printf("== load + use libwg ==\n");
    g_wg = load(wg_path);
    call(g_wg, "wgVersion");
    printf("== load + use libawg (same thread) ==\n");
    g_awg = load(awg_path);
    call(g_awg, "awgVersion");
  } else if (strcmp(mode, "wg-first") == 0) {
    printf("== T1: load + use libwg ==\n");
    on_thread(t_load_wg);
    printf("== T2: load + use libawg ==\n");
    on_thread(t_load_awg);
    printf("== T3: re-enter libwg on a fresh thread ==\n");
    on_thread(t_wg);
    printf("== T4: re-enter libawg on a fresh thread ==\n");
    on_thread(t_awg);
  } else if (strcmp(mode, "awg-first") == 0) {
    printf("== T1: load + use libawg ==\n");
    on_thread(t_load_awg);
    printf("== T2: load + use libwg ==\n");
    on_thread(t_load_wg);
    printf("== T3: re-enter libwg on a fresh thread ==\n");
    on_thread(t_wg);
    printf("== T4: re-enter libawg on a fresh thread ==\n");
    on_thread(t_awg);
  } else if (strcmp(mode, "wg-again") == 0) {
    printf("== load + use libwg ==\n");
    g_wg = load(wg_path);
    call(g_wg, "wgVersion");
    printf("== load libawg (global) ==\n");
    g_awg = load(awg_path);
    printf("== call libwg again on the same thread ==\n");
    call(g_wg, "wgVersion");
  } else if (strcmp(mode, "awg-again") == 0) {
    printf("== load + use libawg ==\n");
    g_awg = load(awg_path);
    call(g_awg, "awgVersion");
    printf("== load libwg (global) ==\n");
    g_wg = load(wg_path);
    printf("== call libawg again on the same thread ==\n");
    call(g_awg, "awgVersion");
  } else if (strcmp(mode, "turnon") == 0) {
    /* Control: libwg only. Should come up, go down, come up again, all clean. */
    printf("== libwg: bring a real device up and down, twice ==\n");
    g_wg = load(wg_path);
    cycle(g_wg, "wg", "bmhwg0");
    cycle(g_wg, "wg", "bmhwg1");
  } else if (strcmp(mode, "turnon-awg") == 0) {
    /* The descent: a libwg up/down, then libawg's runtime live, then libwg up. */
    printf("== libwg: bring a real device up and down ==\n");
    g_wg = load(wg_path);
    cycle(g_wg, "wg", "bmhwg0");
    printf("== libawg: initialize and bring its device up (another thread) ==\n");
    on_thread(t_awg_device);
    printf("== libwg: bring another device up again ==\n");
    cycle(g_wg, "wg", "bmhwg1");
  } else {
    fprintf(stderr, "unknown mode %s\n", mode);
    return 2;
  }
  printf("DONE\n");
  return 0;
}
