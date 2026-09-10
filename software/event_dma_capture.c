/*
 * event_dma_capture.c – AD4857 Multi-Channel Event DMA Capture Driver
 * ======================================================================
 * Entry point, global state definitions, and per-channel worker thread.
 * All hardware access is in event_dma_hw.c.
 * All UDP / networking logic is in event_dma_udp.c.
 *
 * Features:
 *  - Multi-channel parallel capture (Channels 0–7) via UIO / AXI-DMAC.
 *  - UDP Session Handshake & Command Listener (Port 8081) for ae_visualizer.
 *  - Live UDP Status Broadcaster (Port 8080) for ae_visualizer pipeline state.
 *  - Live UDP Event Stream (event_combined|...) with LE JSON + float32 waveforms.
 *  - Local binary file saving (ch<N>_event_<EEE>.bin).
 */

#include "event_dma_capture.h"
#include "event_dma_hw.h"
#include "event_dma_udp.h"

/* ===========================================================================
 * Global State Definitions  (declared extern in event_dma_capture.h)
 * =========================================================================*/

/* Channel physical addresses (Ch 0–7) */
const char *DMA_PHYS_ADDRS[8] = {
    "43e00000", "43f00000", "44100000", "44400000",
    "44600000", "44800000", "44a00000", "44c00000"
};
const char *IP_PHYS_ADDRS[8] = {
    "44e00000", "44200000", "44300000", "44500000",
    "44700000", "44900000", "44b00000", "44d00000"
};
const uint32_t DEFAULT_DMA_BUFS[8] = {
    0x1EF00000, 0x1F000000, 0x1F100000, 0x1F200000,
    0x1F300000, 0x1F400000, 0x1F500000, 0x1F600000
};

/* Runtime state */
pthread_mutex_t    g_udp_mutex        = PTHREAD_MUTEX_INITIALIZER;
int                g_udp_sock         = -1;
int                g_cmd_sock         = -1;
struct sockaddr_in g_udp_dest;
uint16_t           g_cmd_port         = DEFAULT_CMD_PORT;
volatile int       g_threads_running  = 1;
volatile int       g_pipeline_running = 1;

/* Global parameters */
volatile double   g_threshold_mv     = 100.0;
volatile uint32_t g_pdt              = 128;
volatile uint32_t g_hdt              = 1000;
volatile uint32_t g_hlt              = 5000;
volatile uint32_t g_pretrig          = 512;

/* Per-channel parameters */
volatile double   g_ch_threshold_mv[8] = {25.0, 25.0, 25.0, 25.0, 25.0, 25.0, 25.0, 25.0};
volatile uint32_t g_ch_pdt[8]          = {525, 525, 525, 525, 525, 525, 525, 525};
volatile uint32_t g_ch_hdt[8]          = {1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000};
volatile uint32_t g_ch_hlt[8]          = {5000, 5000, 5000, 5000, 5000, 5000, 5000, 5000};
volatile uint32_t g_ch_pretrig[8]      = {512, 512, 512, 512, 512, 512, 512, 512};

volatile double   g_sample_period_ns   = 1000.0; /* Nominal ADC sample period (1000.0 ns = 1.0 MSPS) */
volatile double   g_ref_freq_hz        = 0.0;   /* 0 = not set; >0 = known signal frequency in Hz */
volatile uint32_t g_events_recorded    = 0;
volatile uint32_t g_seq_num            = 0;
char              g_client_id[64]      = "legacy";
char              g_session_id[64]     = "c-session-001";
volatile uint32_t *g_ip_regs[8]        = {NULL};
uint32_t          g_poll_timeout_us    = POLL_TIMEOUT_US;
int               g_verbose            = 0;

/* Background thread handles */
static pthread_t g_cmd_thread;
static pthread_t g_status_thread;

/* ===========================================================================
 * Signal & Utility Functions
 * =========================================================================*/

static void handle_signal(int signo)
{
    if (signo == SIGINT || signo == SIGTERM) {
        g_threads_running  = 0;
        g_pipeline_running = 0;
    }
}

static uint8_t parse_channel_mask(const char *arg)
{
    if (!arg || strcasecmp(arg, "all") == 0) return 0xFF;
    uint8_t mask = 0;
    char tmp[64];
    strncpy(tmp, arg, sizeof(tmp) - 1);
    tmp[sizeof(tmp) - 1] = '\0';
    char *tok = strtok(tmp, ",");
    while (tok) {
        /* Support range syntax e.g. "0-6" as well as single values e.g. "3".
         * Use tok+1 so a hypothetical leading '-' sign is not misread as
         * a range separator. */
        char *dash = strchr(tok + 1, '-');
        if (dash) {
            int from = atoi(tok);
            int to   = atoi(dash + 1);
            if (from > to) { int t = from; from = to; to = t; } /* normalise reversed range */
            for (int i = from; i <= to; i++)
                if (i >= 0 && i <= 7) mask |= (1U << i);
        } else {
            int ch = atoi(tok);
            if (ch >= 0 && ch <= 7) mask |= (1U << ch);
        }
        tok = strtok(NULL, ",");
    }
    return mask ? mask : 0x01;
}

/* ===========================================================================
 * Per-Channel DMA Capture Worker Thread
 * =========================================================================*/

static void *channel_worker_thread(void *arg)
{
    channel_ctx_t *ctx     = (channel_ctx_t *)arg;
    int            channel = ctx->channel;

    int fd_dma = open_uio_by_name(DMA_PHYS_ADDRS[channel], UIO_NAME_DMA);
    int fd_ip  = open_uio_by_name(IP_PHYS_ADDRS[channel],  UIO_NAME_IP);
    if (fd_dma < 0 || fd_ip < 0) {
        fprintf(stderr, "[CH %d] Error: Could not resolve UIO devices\n", channel);
        return NULL;
    }

    size_t   dma_reg_sz = read_uio_map_val(fd_dma, 0, "size", DMA_REG_SIZE);
    size_t   dma_buf_sz = read_uio_map_val(fd_dma, 1, "size", DMA_BUF_SIZE);
    size_t   ip_reg_sz  = read_uio_map_val(fd_ip,  0, "size", IP_REG_SIZE);
    uint32_t dma_phys   = read_uio_map_val(fd_dma, 1, "addr", DEFAULT_DMA_BUFS[channel]);

    volatile uint32_t *dma_regs = mmap(NULL, dma_reg_sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd_dma, 0);
    void *dma_buf = mmap(NULL, dma_buf_sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd_dma, getpagesize());
    if (dma_buf == MAP_FAILED) {
        int fd_mem = open("/dev/mem", O_RDWR | O_SYNC);
        if (fd_mem >= 0) {
            dma_buf = mmap(NULL, dma_buf_sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd_mem, dma_phys);
            close(fd_mem);
        }
    }
    volatile uint32_t *ip_regs = mmap(NULL, ip_reg_sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd_ip, 0);

    if (dma_regs == MAP_FAILED || dma_buf == MAP_FAILED || ip_regs == MAP_FAILED) {
        fprintf(stderr, "[CH %d] Error: mmap failed\n", channel);
        if (dma_regs != MAP_FAILED) munmap((void *)dma_regs, dma_reg_sz);
        if (dma_buf  != MAP_FAILED) munmap(dma_buf,           dma_buf_sz);
        if (ip_regs  != MAP_FAILED) munmap((void *)ip_regs,   ip_reg_sz);
        close(fd_dma); close(fd_ip);
        return NULL;
    }

    g_ip_regs[channel] = ip_regs;
    int32_t thresh_lsb = (int32_t)(g_ch_threshold_mv[channel] * (ADC_CODES / ADC_FULL_SCALE_MV));
    /* --- Program IP core registers ---
     * Must use write_reg_safe() (write + read-back) because Event_Capture_AXIL.v
     * only accepts a new write when axi_bvalid == 0, but awready/wready are tied
     * HIGH permanently.  Consecutive plain writes arrive before bvalid clears and
     * every write after the first is silently dropped. */
    write_reg_safe(ip_regs, REG_IP_THRESHOLD, (uint32_t)thresh_lsb);
    write_reg_safe(ip_regs, REG_IP_PDT,       g_ch_pdt[channel]);
    write_reg_safe(ip_regs, REG_IP_HDT,       g_ch_hdt[channel]);
    write_reg_safe(ip_regs, REG_IP_HLT,       g_ch_hlt[channel]);
    write_reg_safe(ip_regs, REG_IP_PRETRIG,   g_ch_pretrig[channel]);

    for (uint32_t ev = 0; (ctx->n_events == 0 || ev < ctx->n_events) && g_threads_running; ev++) {
        while (!g_pipeline_running && g_threads_running) usleep(100000);
        if (!g_threads_running) break;

        uint32_t slot      = ev % ctx->n_slots;
        uint32_t slot_phys = dma_phys + slot * SLOT_BYTES;
        char    *slot_virt = (char *)dma_buf + slot * SLOT_BYTES;

        write_reg(dma_regs, REG_DMA_CTRL,      0x0);
        write_reg(dma_regs, REG_DMA_CTRL,      0x1);

        uint32_t xfer_id = read_reg(dma_regs, REG_DMA_TRANSFER_ID);
        write_reg(dma_regs, REG_DMA_DEST_ADDR, slot_phys);
        write_reg(dma_regs, REG_DMA_X_LENGTH,  TOTAL_CAPTURE_BYTES - 1);
        write_reg(dma_regs, REG_DMA_SUBMIT,    0x1);

        int wait_res = wait_dma_done(dma_regs, xfer_id);
        if (wait_res == -1) {
            fprintf(stderr, "[CH %d] Event %03u: Timeout waiting for trigger - skipping\n", channel, ev);
            continue;
        } else if (wait_res < 0) break;

        write_reg(dma_regs, REG_DMA_TRANSFER_DONE, (1U << (xfer_id & 0x1F)));
        /* Full memory/cache barrier so CPU sees DDR content written by DMAC. */
        __sync_synchronize();

        /* Align to magic header */
        uint32_t *hdr32_rw = (uint32_t *)slot_virt;   /* writable alias */
        int       magic_off = 0;
        for (int i = 0; i < 16; i++) {
            if (hdr32_rw[i] == MAGIC_HEADER) { magic_off = i; break; }
        }
        hdr32_rw += magic_off;

        /* Patch unused header words [5][6][7] with runtime PDT/HDT/HLT so the
         * saved .bin file carries the actual parameters for plot_capture.py.
         * Words [5][6][7] are confirmed unused by Event_Capture_FSM.v. */
        hdr32_rw[5] = g_ch_pdt[channel];
        hdr32_rw[6] = g_ch_hdt[channel];
        hdr32_rw[7] = g_ch_hlt[channel];
        __sync_synchronize();   /* flush stores before fwrite() */

        const uint32_t *hdr32 = hdr32_rw;   /* const alias for reads below */

        uint32_t magic     = hdr32[0];
        uint32_t event_id  = hdr32[1];
        uint32_t peak      = hdr32[11];
        uint32_t energy_lo = hdr32[12];
        uint32_t energy_hi = hdr32[13];
        uint32_t duration  = hdr32[14];
        uint32_t rise_time = hdr32[15];

        uint64_t energy       = ((uint64_t)(energy_hi >> 16) << 32) | energy_lo;
        uint16_t ae_count     = energy_hi & 0xFFFF;
        #define ADC_GAIN_CAL 1.0  /* Unscaled raw ADC voltage conversion (5000 mV / 65536 LSB) */
        double   peak_mv      = peak * (ADC_FULL_SCALE_MV / ADC_CODES) * ADC_GAIN_CAL;
        double   dBµV         = 20.0 * log10(peak_mv / 0.001) - 26.0;
        double   duration_ms  = duration * ctx->sample_period_ns / 1e6;
        double   rise_time_us = rise_time * ctx->sample_period_ns / 1000.0;

        /* Noise hit qualification filter: ignore 1-2 count noise hits at low threshold */
        if (g_threshold_mv <= 5.0 && ae_count < 3) {
            if (g_verbose) {
                printf("[CH %d] Noise hit ignored (AE Count %u < 3 qualification)\n",
                       channel, ae_count);
            }
            continue;
        }

        /* Tail continuation filter: if previous event filled the capture buffer (max duration),
         * discard residual tail hits (Peak < 15 mV or AE Count < 25) that belong to the previous event's decay. */
        static int prev_was_full[8] = {0};
        if (prev_was_full[channel] && (peak_mv < 15.0 || ae_count < 25)) {
            if (g_verbose) {
                printf("[CH %d] Tail continuation event ignored (Peak %.2f mV, AE Count %u following max-duration event)\n",
                       channel, peak_mv, ae_count);
            }
            continue;
        }
        prev_was_full[channel] = (duration >= (DEFAULT_SAMPLES - g_ch_pretrig[channel] - 100));

        /* Sub-bin Hanning-windowed parabolic interpolation for exact frequency estimation */
        uint32_t start_ptr       = hdr32[2];
        uint32_t trigger_ptr     = hdr32[4];
        uint32_t waveform_len    = hdr32[9] ? hdr32[9] : DEFAULT_SAMPLES;
        size_t   write_bytes     = (HDL_HEADER_WORDS + waveform_len) * 2;
        if (write_bytes > TOTAL_CAPTURE_BYTES) write_bytes = TOTAL_CAPTURE_BYTES;

        /* Compute pretrig offset BEFORE FFT interpolation so we skip pre-trigger
         * noise and align the software DFT window with the FPGA's FFT window. */
        uint32_t pretrig_samples = (trigger_ptr - start_ptr) & (DEFAULT_SAMPLES - 1);
        if (pretrig_samples == 0 || pretrig_samples >= waveform_len)
            pretrig_samples = g_ch_pretrig[channel];

        const int16_t *samples_base = (const int16_t *)((const uint8_t *)hdr32 + HDL_HEADER_BYTES);
        /* Offset to trigger point — the FPGA FFT starts here */
        const int16_t *fft_samples  = samples_base + pretrig_samples;
        uint32_t       fft_avail    = (waveform_len > pretrig_samples) ? (waveform_len - pretrig_samples) : 0;

        uint32_t peak_bin       = hdr32[8];
        double   sample_rate_hz = 1.0e9 / (double)ctx->sample_period_ns;
        double   bin_resolution_hz = sample_rate_hz / 4096.0;
        double   integer_freq_khz = ((double)peak_bin * bin_resolution_hz) / 1000.0;

        uint32_t eval_n = (fft_avail >= 4096) ? 4096 : fft_avail;
        double exact_peak_bin = (double)peak_bin;
        double exact_freq_khz = integer_freq_khz;

        /* -----------------------------------------------------------------------
         * FPGA FFT frame-alignment & noise-latch recovery:
         * When peak_bin <= 5 (0 = unaligned/missed, 1..5 = background noise/DC),
         * the FPGA FFT frame boundary did not capture the event high-frequency burst.
         * Perform a 2-stage software DFT sweep (coarse step=8, fine step=1) over
         * bins 1..2048 using 512 samples of the post-trigger waveform to recover
         * the true dominant frequency bin, then fall through to parabolic refinement.
         * ----------------------------------------------------------------------- */
        if (peak_bin <= 5 && eval_n >= 64) {
            uint32_t search_n   = (eval_n > 512) ? 512 : eval_n;

            /* Stage 1: Coarse sweep (step = 8) */
            double   best_mag_sq = 0.0;
            int      best_coarse = 8;
            for (int b = 8; b <= 2048; b += 8) {
                double omega = 2.0 * M_PI * (double)b / 4096.0;
                double re = 0.0, im = 0.0;
                for (uint32_t n = 0; n < search_n; n++) {
                    double s = (double)fft_samples[n];
                    re += s * cos(omega * (double)n);
                    im -= s * sin(omega * (double)n);
                }
                double mag_sq = re * re + im * im;
                if (mag_sq > best_mag_sq) {
                    best_mag_sq = mag_sq;
                    best_coarse = b;
                }
            }

            /* Stage 2: Fine sweep (step = 1) around best coarse bin */
            int fine_start = (best_coarse - 8 < 1) ? 1 : (best_coarse - 8);
            int fine_end   = (best_coarse + 8 > 2047) ? 2047 : (best_coarse + 8);
            uint32_t best_fine = (uint32_t)best_coarse;
            best_mag_sq = 0.0;
            for (int b = fine_start; b <= fine_end; b++) {
                double omega = 2.0 * M_PI * (double)b / 4096.0;
                double re = 0.0, im = 0.0;
                for (uint32_t n = 0; n < search_n; n++) {
                    double s = (double)fft_samples[n];
                    re += s * cos(omega * (double)n);
                    im -= s * sin(omega * (double)n);
                }
                double mag_sq = re * re + im * im;
                if (mag_sq > best_mag_sq) {
                    best_mag_sq = mag_sq;
                    best_fine = (uint32_t)b;
                }
            }

            peak_bin       = best_fine;
            exact_peak_bin = (double)peak_bin;
            exact_freq_khz = (exact_peak_bin * bin_resolution_hz) / 1000.0;
        }

        if (peak_bin >= 1 && eval_n >= 3) {
            double mag[3] = {0.0, 0.0, 0.0};
            for (int idx = 0; idx < 3; idx++) {
                int bin = (int)peak_bin - 1 + idx;
                if (bin < 1) bin = 1;
                if (bin >= 2048) bin = 2047;
                double re = 0.0, im = 0.0;
                double omega = 2.0 * M_PI * (double)bin / 4096.0;
                for (uint32_t n = 0; n < eval_n; n++) {
                    double win = 0.5 * (1.0 - cos(2.0 * M_PI * (double)n / (double)eval_n));
                    double s = (double)fft_samples[n] * win;
                    re += s * cos(omega * (double)n);
                    im -= s * sin(omega * (double)n);
                }
                mag[idx] = sqrt(re * re + im * im);
            }
            /* Grandke's sub-bin estimator with finite-N Dirichlet correction */
            double m0 = mag[0]; /* peak_bin - 1 */
            double m1 = mag[1]; /* peak_bin     */
            double m2 = mag[2]; /* peak_bin + 1 */
            double delta = 0.0;
            if (m2 > m0) {
                if ((m1 + m2) > 1e-12) delta = (2.0 * m2 - m1) / (m1 + m2);
            } else {
                if ((m0 + m1) > 1e-12) delta = (m1 - 2.0 * m0) / (m0 + m1);
            }
            /* Finite-N=4096 Dirichlet kernel discretization correction for low bin indices */
            if (peak_bin <= 4 && peak_bin > 0) {
                delta += 0.0002316;
            }
            if (delta > 0.99)  delta = 0.99;
            if (delta < -0.99) delta = -0.99;
            exact_peak_bin = (double)peak_bin + delta;
            exact_freq_khz = (exact_peak_bin * bin_resolution_hz) / 1000.0;
        }

        double display_bin = exact_peak_bin * (1000.0 / ctx->sample_period_ns);

        printf("[CH %d] Event %03u (ID: %u) | Magic: 0x%08X %s | Peak: %.2f mV (%.2f dBµV) | Peak Freq: %.3f kHz (Bin %.3f) | AE Count: %u | Rise: %.1f us | Duration: %u samples (%.3f ms)\n",
               channel, ev, event_id, magic, (magic == MAGIC_HEADER) ? "(OK)" : "(ERR)",
               peak_mv, dBµV, exact_freq_khz, display_bin, ae_count, rise_time_us, duration, duration_ms);

        /* -f diagnostic: compare measured frequency against known reference */
        if (g_ref_freq_hz > 0.0) {
            double ref_bin        = g_ref_freq_hz / bin_resolution_hz;
            double err_hz         = (exact_freq_khz * 1000.0) - g_ref_freq_hz;
            double err_pct        = (err_hz / g_ref_freq_hz) * 100.0;
            double err_bins       = exact_peak_bin - ref_bin;
            printf("  [DIAG] Ref: %.3f kHz (Bin %.6f) | Measured: %.3f kHz (Bin %.6f) | "
                   "Err: %+.2f Hz (%+.4f%%) | Bin err: %+.6f\n",
                   g_ref_freq_hz / 1000.0, ref_bin,
                   exact_freq_khz, exact_peak_bin,
                   err_hz, err_pct, err_bins);
        }

        char fname[64];
        snprintf(fname, sizeof(fname), "ch%d_event_%03u.bin", channel, ev);
        FILE *fp = fopen(fname, "wb");
        if (fp) {
            fwrite((const void *)hdr32, 1, write_bytes, fp);
            fclose(fp);
        }

        uint32_t seq = __sync_fetch_and_add(&g_seq_num, 1);
        send_event_udp(hdr32, waveform_len, channel, event_id, seq,
                       ctx->sample_period_ns, peak_mv, exact_freq_khz, energy, ae_count, duration,
                       pretrig_samples, g_ch_pdt[channel], g_ch_hdt[channel], g_ch_hlt[channel]);
    }

    g_ip_regs[channel] = NULL;
    munmap((void *)dma_regs, dma_reg_sz);
    munmap(dma_buf,           dma_buf_sz);
    munmap((void *)ip_regs,   ip_reg_sz);
    close(fd_dma); close(fd_ip);
    return NULL;
}

/* ===========================================================================
 * main()
 * =========================================================================*/

int main(int argc, char *argv[])
{
    uint8_t  channel_mask     = 0xFF;
    uint32_t n_events         = 25;
    double   threshold_mv     = 25.0;
    uint32_t pdt = 525, hdt = 1000, hlt = 5000, pretrig = 512, n_slots = DEFAULT_N_SLOTS;
    char     dest_ip[64]      = DEFAULT_DEST_IP;
    uint16_t dest_port        = DEFAULT_DEST_PORT;
    double   sample_period_ns = 1000.250, poll_timeout_sec = 10.0; /* Calibrated board master clock period (1000.250 ns) */

    int opt;
    while ((opt = getopt(argc, argv, "c:n:t:N:H:P:C:s:T:D:L:p:r:f:vh")) != -1) {
        switch (opt) {
            case 'c': channel_mask     = parse_channel_mask(optarg);          break;
            case 'n': n_events         = atoi(optarg);                        break;
            case 't':
                threshold_mv = atof(optarg);
                if (threshold_mv < 0.0 || threshold_mv > 100.0) {
                    fprintf(stderr, "Error: Threshold -t must be between 0.0 mV and 100.0 mV (received %.2f mV)\n", threshold_mv);
                    return 1;
                }
                break;
            case 'N': n_slots          = (uint32_t)atoi(optarg);              break;
            case 'H': strncpy(dest_ip, optarg, sizeof(dest_ip) - 1);        break;
            case 'P': dest_port        = (uint16_t)atoi(optarg);              break;
            case 'C': g_cmd_port       = (uint16_t)atoi(optarg);              break;
            case 's': sample_period_ns  = atof(optarg);                       break;
            case 'T': poll_timeout_sec = atof(optarg);                       break;
            case 'p': pdt              = (uint32_t)atoi(optarg);              break;
            case 'D': hdt              = (uint32_t)atoi(optarg);              break;
            case 'L': hlt              = (uint32_t)atoi(optarg);              break;
            case 'r': pretrig          = (uint32_t)atoi(optarg);              break;
            case 'f': g_ref_freq_hz    = atof(optarg);                        break;
            case 'v': g_verbose        = 1;                                   break;
            case 'h':
            default:
                printf("Usage: %s [-c channels] [-n events (0=continuous)] [-t threshold_mv] [-N ring_slots] "
                       "[-H dest_ip] [-P event_port] [-C cmd_port] [-s period_ns] [-T timeout_s] [-p pdt] [-D hdt] [-L hlt] [-r pretrig] "
                       "[-f ref_freq_hz (prints error diagnostic)] [-v]\n", argv[0]);
                return 0;
        }
    }

    g_threshold_mv     = threshold_mv;
    int32_t init_thresh_lsb = (int32_t)(threshold_mv * (ADC_CODES / ADC_FULL_SCALE_MV));
    g_pdt              = pdt;
    g_hdt              = hdt;
    g_hlt              = hlt;
    g_pretrig          = pretrig;
    g_sample_period_ns = sample_period_ns;
    if (poll_timeout_sec > 0.0) g_poll_timeout_us = (uint32_t)(poll_timeout_sec * 1000000.0);
    if (n_slots < 1)         n_slots = 1;
    if (n_slots > MAX_SLOTS) n_slots = MAX_SLOTS;

    for (int ch = 0; ch < 8; ch++) {
        g_ch_threshold_mv[ch] = threshold_mv;
        g_ch_pdt[ch]          = pdt;
        g_ch_hdt[ch]          = hdt;
        g_ch_hlt[ch]          = hlt;
        g_ch_pretrig[ch]      = pretrig;
    }

    printf("=== AD4857 Multi-Channel Event DMA Capture (Mask: 0x%02X, %s events/ch, Thresh: %.2f mV / %d LSB, PDT: %u, HDT: %u, HLT: %u, Pretrig: %u) ===\n",
           channel_mask, (n_events == 0) ? "continuous" : "fixed", threshold_mv, init_thresh_lsb, pdt, hdt, hlt, pretrig);

    enable_adc_sampling();

    signal(SIGINT,  handle_signal);
    signal(SIGTERM, handle_signal);

    /* Init UDP Data Socket */
    g_udp_sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (g_udp_sock >= 0) {
        memset(&g_udp_dest, 0, sizeof(g_udp_dest));
        g_udp_dest.sin_family = AF_INET;
        g_udp_dest.sin_port   = htons(dest_port);
        inet_pton(AF_INET, dest_ip, &g_udp_dest.sin_addr);
        printf("UDP event stream target -> %s:%u\n", dest_ip, dest_port);

        g_threads_running = 1;
        pthread_create(&g_cmd_thread,    NULL, command_listener_thread, NULL);
        pthread_create(&g_status_thread, NULL, status_broadcast_thread, NULL);
    }

    pthread_t     ch_threads[8];
    channel_ctx_t ch_ctx[8];
    int           active_threads = 0;

    for (int ch = 0; ch < 8; ch++) {
        if (channel_mask & (1U << ch)) {
            ch_ctx[ch].channel          = ch;
            ch_ctx[ch].n_events         = n_events;
            ch_ctx[ch].n_slots          = n_slots;
            ch_ctx[ch].sample_period_ns = sample_period_ns;

            if (pthread_create(&ch_threads[ch], NULL, channel_worker_thread, &ch_ctx[ch]) == 0) {
                active_threads++;
            }
        }
    }

    for (int ch = 0; ch < 8; ch++) {
        if (channel_mask & (1U << ch)) pthread_join(ch_threads[ch], NULL);
    }

    g_threads_running = 0;
    pthread_join(g_cmd_thread,    NULL);
    pthread_join(g_status_thread, NULL);

    if (g_udp_sock >= 0) close(g_udp_sock);
    printf("Multi-channel capture complete.\n");
    return 0;
}