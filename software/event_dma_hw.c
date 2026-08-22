/*
 * event_dma_hw.c – Hardware access & UIO driver implementation
 * =============================================================
 * Handles UIO device resolution, sysfs parameter queries,
 * DMAC completion polling, and IIO / PWM CNV clock activation.
 */

#include "event_dma_hw.h"

/* Find UIO device node by physical address match (Pass 1) or fallback name (Pass 2) */
int open_uio_by_name(const char *target_addr, const char *alt_name)
{
    DIR *d = opendir("/sys/class/uio");
    if (!d) return -1;

    struct dirent *ent;
    char path[300], name[128], linkpath[300];

    /* --- Pass 1: Match by target physical address --- */
    if (target_addr && target_addr[0] != '\0') {
        while ((ent = readdir(d)) != NULL) {
            if (strncmp(ent->d_name, "uio", 3) != 0) continue;

            snprintf(path, sizeof(path), "/sys/class/uio/%s/name", ent->d_name);
            FILE *fp = fopen(path, "r");
            if (!fp) continue;
            if (!fgets(name, sizeof(name), fp)) { fclose(fp); continue; }
            fclose(fp);
            name[strcspn(name, "\r\n")] = '\0';

            snprintf(path, sizeof(path), "/sys/class/uio/%s", ent->d_name);
            ssize_t len = readlink(path, linkpath, sizeof(linkpath) - 1);
            if (len > 0) linkpath[len] = '\0'; else linkpath[0] = '\0';

            if (strstr(name, target_addr) || strstr(linkpath, target_addr)) {
                snprintf(path, sizeof(path), "/dev/%s", ent->d_name);
                closedir(d);
                return open(path, O_RDWR);
            }
        }
        rewinddir(d);
    }

    /* --- Pass 2: Fallback by UIO module name if physical address not supplied/found --- */
    if (alt_name && alt_name[0] != '\0') {
        while ((ent = readdir(d)) != NULL) {
            if (strncmp(ent->d_name, "uio", 3) != 0) continue;

            snprintf(path, sizeof(path), "/sys/class/uio/%s/name", ent->d_name);
            FILE *fp = fopen(path, "r");
            if (!fp) continue;
            if (!fgets(name, sizeof(name), fp)) { fclose(fp); continue; }
            fclose(fp);
            name[strcspn(name, "\r\n")] = '\0';

            snprintf(path, sizeof(path), "/sys/class/uio/%s", ent->d_name);
            ssize_t len = readlink(path, linkpath, sizeof(linkpath) - 1);
            if (len > 0) linkpath[len] = '\0'; else linkpath[0] = '\0';

            if (strstr(name, alt_name) || strstr(linkpath, alt_name)) {
                snprintf(path, sizeof(path), "/dev/%s", ent->d_name);
                closedir(d);
                return open(path, O_RDWR);
            }
        }
    }

    closedir(d);
    return -1;
}

/* Read UIO sysfs map parameter (size or addr) */
unsigned long read_uio_map_val(int fd, int map_idx, const char *entry, unsigned long def_val)
{
    char fdpath[64], target[256], syspath[300];
    snprintf(fdpath, sizeof(fdpath), "/proc/self/fd/%d", fd);
    ssize_t len = readlink(fdpath, target, sizeof(target) - 1);
    if (len <= 0) return def_val;
    target[len] = '\0';

    const char *devname = strrchr(target, '/');
    if (!devname) return def_val;
    devname++;

    snprintf(syspath, sizeof(syspath), "/sys/class/uio/%s/maps/map%d/%s", devname, map_idx, entry);
    FILE *fp = fopen(syspath, "r");
    if (!fp) return def_val;

    unsigned long val = def_val;
    if (fscanf(fp, "%lx", &val) != 1) val = def_val;
    fclose(fp);
    return val;
}

/* Poll DMA done register until complete or timeout */
int wait_dma_done(volatile uint32_t *dma_regs, uint32_t xfer_id)
{
    uint32_t elapsed = 0;
    uint32_t mask = (1U << (xfer_id & 0x1F));

    while (!(read_reg(dma_regs, REG_DMA_TRANSFER_DONE) & mask)) {
        if (!g_threads_running || !g_pipeline_running) return -2;
        usleep(POLL_INTERVAL_US);
        elapsed += POLL_INTERVAL_US;
        if (elapsed >= g_poll_timeout_us) return -1;
    }
    return 0;
}

/* Automatically enable ADC conversion clock if idle */
void enable_adc_sampling(void)
{
    for (int dev = 1; dev < 5; dev++) {
        char scanpath[128];
        snprintf(scanpath, sizeof(scanpath),
                 "/sys/bus/iio/devices/iio:device%d/scan_elements/in_voltage0_en", dev);
        if (access(scanpath, F_OK) == 0) {
            char cmd[512];
            snprintf(cmd, sizeof(cmd),
                     "echo 1 > /sys/bus/iio/devices/iio:device%d/scan_elements/in_voltage0_en 2>/dev/null; "
                     "echo 100 > /sys/bus/iio/devices/iio:device%d/buffer/length 2>/dev/null; "
                     "echo 1 > /sys/bus/iio/devices/iio:device%d/buffer/enable 2>/dev/null",
                     dev, dev, dev);
            int ret = system(cmd);
            (void)ret;
            if (g_verbose) printf("Enabled CNV sampling clock on IIO device%d\n", dev);
            return;
        }
    }

    int fd_mem = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd_mem >= 0) {
        volatile uint32_t *pwm = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE,
                                      MAP_SHARED, fd_mem, 0x43d00000);
        if (pwm != MAP_FAILED) {
            pwm[0x40 / 4] = 8; /* PERIOD */
            pwm[0x44 / 4] = 1; /* DUTY */
            pwm[0x10 / 4] = 1; /* ENABLE */
            pwm[0x14 / 4] = 1; /* LOAD */
            munmap((void *)pwm, 0x1000);
            if (g_verbose) printf("Forced CNV clock via axi_pwm_gen (0x43d00000)\n");
        }
        close(fd_mem);
    }
}
