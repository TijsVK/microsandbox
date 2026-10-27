// fsbench: per-operation latency of small synchronous writes, the pattern of dpkg, git and databases.
// Build: gcc -O2 -static -o fsbench fsbench.c      Run: fsbench <dir> [count]
// Modes (each <count> operations, one 4 KiB write per op, file in <dir>):
//   overwrite+fsync      pwrite at offset 0 of one preallocated file, then fsync
//   overwrite+fdatasync  same with fdatasync (only the timestamps change: no journal commit needed)
//   append+fsync         append to one file, then fsync (size changes: metadata journal)
//   append+fdatasync     same with fdatasync
//   newfile+fsync        create a new file, write, fsync, close (dpkg's per-file pattern)
// Prints one line per mode: count, total ms, mean, p50, p90, p99, max (ms).
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}
static int cmp(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}
static void report(const char *mode, double *v, int n) {
    double total = 0;
    for (int i = 0; i < n; i++) total += v[i];
    qsort(v, n, sizeof *v, cmp);
    printf("%-20s n=%-4d total=%9.1fms mean=%7.2f p50=%7.2f p90=%7.2f p99=%7.2f max=%7.2f\n", mode, n,
           total, total / n, v[n / 2], v[n * 9 / 10], v[n * 99 / 100], v[n - 1]);
    fflush(stdout);
}
static void die(const char *what) { perror(what); exit(1); }

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <dir> [count]\n", argv[0]); return 2; }
    const char *dir = argv[1];
    int n = argc > 2 ? atoi(argv[2]) : 100;
    const char *only = getenv("FSBENCH_MODE");
    double *lat = calloc(n, sizeof *lat);
    char buf[4096], path[4096];
    memset(buf, 'x', sizeof buf);

    for (int ds = 0; ds < 2; ds++) {
        if (only && strcmp(only, ds ? "overwrite-fdatasync" : "overwrite")) continue;
        snprintf(path, sizeof path, "%s/fsbench-ow", dir);
        int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644);
        if (fd < 0) die("open");
        if (pwrite(fd, buf, sizeof buf, 0) != sizeof buf || fsync(fd)) die("prep");
        for (int i = 0; i < n; i++) {
            double t = now_ms();
            if (pwrite(fd, buf, sizeof buf, 0) != sizeof buf) die("pwrite");
            if (ds ? fdatasync(fd) : fsync(fd)) die("sync");
            lat[i] = now_ms() - t;
        }
        close(fd); unlink(path);
        report(ds ? "overwrite+fdatasync" : "overwrite+fsync", lat, n);
    }
    for (int ds = 0; ds < 2; ds++) {
        if (only && strcmp(only, ds ? "append-fdatasync" : "append")) continue;
        snprintf(path, sizeof path, "%s/fsbench-ap", dir);
        int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY | O_APPEND, 0644);
        if (fd < 0) die("open");
        for (int i = 0; i < n; i++) {
            double t = now_ms();
            if (write(fd, buf, sizeof buf) != sizeof buf) die("write");
            if (ds ? fdatasync(fd) : fsync(fd)) die("sync");
            lat[i] = now_ms() - t;
        }
        close(fd); unlink(path);
        report(ds ? "append+fdatasync" : "append+fsync", lat, n);
    }
    if (!only || !strcmp(only, "newfile")) {
        for (int i = 0; i < n; i++) {
            snprintf(path, sizeof path, "%s/fsbench-nf-%d", dir, i);
            double t = now_ms();
            int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644);
            if (fd < 0) die("open");
            if (write(fd, buf, sizeof buf) != sizeof buf) die("write");
            if (fsync(fd)) die("fsync");
            close(fd);
            lat[i] = now_ms() - t;
        }
        for (int i = 0; i < n; i++) {
            snprintf(path, sizeof path, "%s/fsbench-nf-%d", dir, i);
            unlink(path);
        }
        report("newfile+fsync", lat, n);
    }
    return 0;
}
