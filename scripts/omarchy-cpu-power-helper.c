/*
 * omarchy-cpu-power-helper — prints Intel RAPL's raw energy counters, for
 * the caller to turn into watts between two calls:
 *
 *   line 1: CLOCK_MONOTONIC in nanoseconds, when the counters were read
 *   line 2: CPU package energy in microjoules (summed over top-level zones)
 *   line 3: RAM energy in microjoules           } only where RAPL has a
 *   line 4: RAM power limit in watts (0 = none)  } "dram" zone
 *
 * It used to sleep 200ms between two reads and print watts. Polled every 2s
 * by the bar, that window kept landing on the bar's own process spawns
 * waking the CPU, so it read 15-20 W on a package averaging 7 W. Counters
 * read at each poll give the true average over the whole interval.
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
/* Room for a zone directory plus the longest file name read inside it. */
#define ZONE_FILE_MAX (PATH_MAX_LOCAL + 32)

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

/* The "dram" subzone ("intel-rapl:0:2" on a Haswell desktop), if any: its
 * directory goes in dir. Returns 0 when there is none. */
static int find_dram(char dir[PATH_MAX_LOCAL]) {
    const char *base = "/sys/class/powercap";
    DIR *d = opendir(base);
    if (!d) return 0;

    int found = 0;
    struct dirent *ent;
    while (!found && (ent = readdir(d)) != NULL) {
        const char *name = ent->d_name;
        if (strncmp(name, "intel-rapl:", 11) != 0) continue;
        if (strchr(name + 11, ':') == NULL) continue;

        char path[ZONE_FILE_MAX], zone[16] = "";
        snprintf(path, sizeof path, "%s/%s/name", base, name);
        FILE *f = fopen(path, "r");
        if (!f) continue;
        if (fscanf(f, "%15s", zone) == 1 && strcmp(zone, "dram") == 0) {
            snprintf(dir, PATH_MAX_LOCAL, "%s/%s", base, name);
            found = 1;
        }
        fclose(f);
    }
    closedir(d);
    return found;
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

/* RAM power limit in watts, 0 unless the dram zone has one enabled. */
static double dram_limit(const char *dir) {
    char path[ZONE_FILE_MAX];
    snprintf(path, sizeof path, "%s/enabled", dir);
    if (read_energy(path) != 1) return 0.0;
    snprintf(path, sizeof path, "%s/constraint_0_power_limit_uw", dir);
    long uw = read_energy(path);
    return uw > 0 ? uw / 1e6 : 0.0;
}

int main(void) {
    char paths[MAX_ZONES][PATH_MAX_LOCAL];
    int count = find_zones(paths);
    if (count == 0) return 0;

    char dram[PATH_MAX_LOCAL], dram_energy[ZONE_FILE_MAX];
    int has_dram = find_dram(dram);
    if (has_dram) snprintf(dram_energy, sizeof dram_energy, "%s/energy_uj", dram);

    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    long cpu = sum_energy(paths, count);
    if (cpu < 0) return 0;

    printf("%lld\n%ld\n", (long long)now.tv_sec * 1000000000LL + now.tv_nsec, cpu);
    long ram = has_dram ? read_energy(dram_energy) : -1;
    if (ram >= 0) printf("%ld\n%.1f\n", ram, dram_limit(dram));
    return 0;
}
