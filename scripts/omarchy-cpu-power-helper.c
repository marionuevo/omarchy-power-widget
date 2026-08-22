/*
 * omarchy-cpu-power-helper — prints instantaneous CPU package power draw in
 * watts, sampled over ~200ms via Intel RAPL.
 *
 * Runs with cap_dac_read_search (via setcap) so it alone can read the
 * root-only intel-rapl energy_uj counters under /sys/class/powercap,
 * instead of widening their permissions system-wide. Takes no arguments,
 * reads no environment, only ever reads these fixed sysfs paths - kept
 * intentionally minimal since it runs with an elevated capability.
 */
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_ZONES 16
#define PATH_MAX_LOCAL 512

static int find_zones(char paths[MAX_ZONES][PATH_MAX_LOCAL]) {
    const char *base = "/sys/class/powercap";
    DIR *d = opendir(base);
    if (!d) return 0;

    int count = 0;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL && count < MAX_ZONES) {
        const char *name = ent->d_name;
        if (strncmp(name, "intel-rapl:", 11) != 0) continue;

        /* Keep top-level zones ("intel-rapl:0"), skip subzones
         * ("intel-rapl:0:0") — count colons after the prefix. */
        const char *rest = name + 11;
        if (strchr(rest, ':') != NULL) continue;

        snprintf(paths[count], PATH_MAX_LOCAL, "%s/%s/energy_uj", base, name);
        count++;
    }
    closedir(d);
    return count;
}

static long read_energy(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    long v = -1;
    if (fscanf(f, "%ld", &v) != 1) v = -1;
    fclose(f);
    return v;
}

static long sum_energy(char paths[MAX_ZONES][PATH_MAX_LOCAL], int count) {
    long sum = 0;
    for (int i = 0; i < count; i++) {
        long v = read_energy(paths[i]);
        if (v < 0) return -1;
        sum += v;
    }
    return sum;
}

int main(void) {
    char paths[MAX_ZONES][PATH_MAX_LOCAL];
    int count = find_zones(paths);
    if (count == 0) {
        printf("0.0\n");
        return 0;
    }

    struct timespec t1, t2;
    long e1 = sum_energy(paths, count);
    clock_gettime(CLOCK_MONOTONIC, &t1);

    struct timespec sleep_dur = { .tv_sec = 0, .tv_nsec = 200000000L };
    nanosleep(&sleep_dur, NULL);

    long e2 = sum_energy(paths, count);
    clock_gettime(CLOCK_MONOTONIC, &t2);

    if (e1 < 0 || e2 < 0 || e2 < e1) {
        /* Read failure or counter wraparound mid-sample; skip rather than
         * report a garbage spike. */
        printf("0.0\n");
        return 0;
    }

    double delta_e_uj = (double)(e2 - e1);
    double delta_t_s = (t2.tv_sec - t1.tv_sec) + (t2.tv_nsec - t1.tv_nsec) / 1e9;
    if (delta_t_s <= 0) {
        printf("0.0\n");
        return 0;
    }

    double watts = (delta_e_uj / 1e6) / delta_t_s;
    printf("%.1f\n", watts);
    return 0;
}
