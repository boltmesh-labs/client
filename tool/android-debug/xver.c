/* xver — reproduce the two-Go-c-shared-library conflict without a VPN.
 *
 * The BoltMesh Android app links libwg-go.so (the stock WireGuard plugin) and
 * libawg-go.so (the in-process AWG host) into one process. They export the same
 * cgo runtime symbols (crosscall2, _cgo_*, x_cgo_*), so whichever is loaded
 * first has those references preempted by the second. This loads both and calls
 * each one's version function to show the fault:
 *
 *   xver <libwg> <libawg> same-thread    # crashes: a thread enters both
 *   xver <libwg> <libawg> wg-first       # each runtime on its own thread
 *   xver <libwg> <libawg> awg-first
 *
 * `same-thread` is the deterministic repro (fault addr 0x38 inside the second
 * library's cgocallback). The thread modes are clean, which is why Java-side
 * thread confinement is necessary but not sufficient: the app still faults on a
 * thread that never entered the other runtime, because the call itself is
 * preempted into the other library's code.
 *
 * Build with tool/android-debug/build.sh; see README.md for the run.
 */
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef const char *(*ver_fn)(void);

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

static void on_thread(void *(*fn)(void *)) {
  pthread_t t;
  pthread_create(&t, NULL, fn, NULL);
  pthread_join(t, NULL);
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IONBF, 0);
  if (argc < 4) {
    fprintf(stderr, "usage: xver <libwg> <libawg> [same-thread|wg-first|awg-first]\n");
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
  } else {
    fprintf(stderr, "unknown mode %s\n", mode);
    return 2;
  }
  printf("DONE\n");
  return 0;
}
