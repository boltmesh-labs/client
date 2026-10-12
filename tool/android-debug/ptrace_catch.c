/* ptrace_catch — report the faulting thread of a process that dies to a signal.
 *
 * Android's debuggerd never sees the crash when a Go runtime owns the SIGSEGV
 * handler (two Go c-shared libraries in the BoltMesh Android app do), so there
 * is no tombstone and no logcat dump. This attaches to every thread of <pid>,
 * forwards signals unchanged, and for each fatal-class signal (SEGV/BUS/ABRT/
 * ILL/FPE) logs the faulting tid, thread name, RIP, RSP and the
 * /proc/<pid>/maps entry that contains RIP. The last FAULT# before END is the
 * crash; earlier ones (e.g. ART's JIT SIGBUS) are the runtime's own use of
 * signals and are harmless.
 *
 * Build with tool/android-debug/build.sh, push, and run as root on a userdebug
 * image once the target pid exists:
 *
 *   adb shell /data/local/tmp/ptrace_catch "$(adb shell pidof <pkg>)"
 *
 * A ptrace tracer can attach to any thread the caller may ptrace; running as
 * root on a userdebug/eng build covers an app process.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/user.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef __WALL
#define __WALL 0x40000000
#endif

static pid_t g_pid;

/* The /proc/<pid>/maps line whose range contains rip, plus the offset into the
 * mapping. For an APK-mapped shared object the path is the apk, so the file
 * offset plus the mapping size is what names which library it really is. */
static void module_of(unsigned long rip, char *out, size_t n) {
  char p[64];
  snprintf(p, sizeof p, "/proc/%d/maps", g_pid);
  out[0] = '\0';
  FILE *f = fopen(p, "r");
  if (!f) {
    snprintf(out, n, "(maps unreadable)");
    return;
  }
  char line[512];
  while (fgets(line, sizeof line, f)) {
    unsigned long lo, hi, off;
    char perms[8];
    int got = sscanf(line, "%lx-%lx %7s %lx %*s %*s", &lo, &hi, perms, &off);
    if (got >= 4 && rip >= lo && rip < hi) {
      char *nl = strchr(line, '\n');
      if (nl) *nl = '\0';
      snprintf(out, n, "%s | liboff=%#lx", line, rip - lo);
      break;
    }
  }
  fclose(f);
}

static void comm_of(pid_t tid, char *out, size_t n) {
  char p[64];
  snprintf(p, sizeof p, "/proc/%d/task/%d/comm", g_pid, tid);
  out[0] = '\0';
  FILE *f = fopen(p, "r");
  if (!f) {
    snprintf(out, n, "?");
    return;
  }
  if (fgets(out, n, f)) {
    char *nl = strchr(out, '\n');
    if (nl) *nl = '\0';
  }
  fclose(f);
}

static void attach_thread(pid_t tid) {
  if (ptrace(PTRACE_ATTACH, tid, 0, 0) == 0) {
    int st;
    waitpid(tid, &st, __WALL);
    ptrace(PTRACE_SETOPTIONS, tid, 0, PTRACE_O_TRACECLONE);
    ptrace(PTRACE_CONT, tid, 0, 0);
  }
}

static void for_each_task(pid_t pid, void (*fn)(pid_t)) {
  char path[64];
  snprintf(path, sizeof path, "/proc/%d/task", pid);
  DIR *d = opendir(path);
  if (!d) return;
  struct dirent *e;
  while ((e = readdir(d))) {
    if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
    fn(atoi(e->d_name));
  }
  closedir(d);
}

static void attach_all(pid_t pid) { for_each_task(pid, attach_thread); }

static void detach_thread(pid_t tid) { ptrace(PTRACE_DETACH, tid, 0, 0); }

/* Leave no thread ptrace-stopped if we bail out before the process dies. */
static void detach_all(pid_t pid) { for_each_task(pid, detach_thread); }

int main(int argc, char **argv) {
  setvbuf(stderr, NULL, _IONBF, 0);
  if (argc < 2) {
    fprintf(stderr, "usage: ptrace_catch <pid>\n");
    return 2;
  }
  g_pid = atoi(argv[1]);
  fprintf(stderr, "attaching to %d\n", g_pid);
  attach_all(g_pid);
  fprintf(stderr, "attached\n");

  int nfault = 0, st;
  pid_t tid;
  while ((tid = waitpid(-1, &st, __WALL)) > 0) {
    if (WIFSTOPPED(st)) {
      int sig = WSTOPSIG(st);
      unsigned ev = (unsigned)st >> 8;
      if (ev == (unsigned)(SIGTRAP | (PTRACE_EVENT_CLONE << 8))) {
        unsigned long nt = 0;
        ptrace(PTRACE_GETEVENTMSG, tid, 0, &nt);
        ptrace(PTRACE_SETOPTIONS, (pid_t)nt, 0, PTRACE_O_TRACECLONE);
        ptrace(PTRACE_CONT, tid, 0, 0);
        continue;
      }
      if (sig == SIGSEGV || sig == SIGBUS || sig == SIGABRT || sig == SIGILL ||
          sig == SIGFPE) {
        struct user_regs_struct r;
        if (ptrace(PTRACE_GETREGS, tid, 0, &r) == 0) {
          char mod[600], comm[64];
          module_of(r.rip, mod, sizeof mod);
          comm_of(tid, comm, sizeof comm);
          nfault++;
          fprintf(stderr,
                  "FAULT#%d tid=%d comm=%s sig=%d rip=%#llx rsp=%#llx\n  %s\n",
                  nfault, tid, comm, sig, (unsigned long long)r.rip,
                  (unsigned long long)r.rsp, mod);
        }
      }
      ptrace(PTRACE_CONT, tid, 0, sig);
    } else if (WIFEXITED(st) || WIFSIGNALED(st)) {
      /* Only the thread-group leader ending means the process is gone; a worker
       * exiting is normal and must not stop the trace. */
      if (tid == g_pid) {
        if (WIFSIGNALED(st))
          fprintf(stderr, "END leader killed by signal %d after %d fault(s)\n",
                  WTERMSIG(st), nfault);
        else
          fprintf(stderr, "END leader exited code=%d after %d fault(s)\n",
                  WEXITSTATUS(st), nfault);
        break;
      }
    }
  }
  detach_all(g_pid);
  return 0;
}
