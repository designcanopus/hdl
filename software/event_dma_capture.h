#ifndef EVENT_DMA_CAPTURE_H
#define EVENT_DMA_CAPTURE_H

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <dirent.h>
#include <errno.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <signal.h>
#include <pthread.h>

/* ---------- Hardware Mapping ---------- */
#define UIO_NAME_DMA "dmem-uio"
#define UIO_NAME_IP  "event_capture"

#define REG_DMA_CTRL          0x0400
#define REG_DMA_TRANSFER_ID   0x0404
#define REG_DMA_SUBMIT        0x0408
#define REG_DMA_DEST_ADDR     0x0410
#define REG_DMA_X_LENGTH      0x0418
#define REG_DMA_TRANSFER_DONE 0x0428

#define REG_IP_THRESHOLD      0x00
#define REG_IP_PDT            0x04
#define REG_IP_HDT            0x08
#define REG_IP_HLT            0x0C
#define REG_IP_PRETRIG        0x24

/* ---------- Defaults & Sizes ---------- */
#define DEFAULT_SAMPLES      16384
#define HDL_HEADER_WORDS     32
#define HDL_HEADER_BYTES     (HDL_HEADER_WORDS * 2)
#define TOTAL_CAPTURE_BYTES  ((HDL_HEADER_WORDS + DEFAULT_SAMPLES) * 2) /* 32832 bytes raw */
#define SLOT_BYTES           0x8100 /* 33024 bytes: 256-byte-aligned block >= 32832 for DMA alignment */
#define DEFAULT_N_SLOTS      16
#define MAX_SLOTS            31

#define DMA_REG_SIZE         0x1000
#define DMA_BUF_SIZE         0x100000 /* 1 MB */
#define IP_REG_SIZE          0x1000

#define POLL_TIMEOUT_US      (10 * 1000 * 1000)
#define POLL_INTERVAL_US     100
#define MAGIC_HEADER         0xAE5EE5AE

/* ---------- UDP Constants ---------- */
#define UDP_HEADER_TAG       "event_combined|"
#define UDP_HEADER_LEN       15
#define DEFAULT_DEST_IP      "127.0.0.1"
#define DEFAULT_DEST_PORT    8080
#define DEFAULT_CMD_PORT     8081
#define ADC_FULL_SCALE_MV    5000.0
#define ADC_CODES            65536.0

/* Channel context structure */
typedef struct {
    int      channel;
    uint32_t n_events;
    uint32_t n_slots;
    double   sample_period_ns;
} channel_ctx_t;

/* ---------- Global State Declarations ---------- */
extern const char *DMA_PHYS_ADDRS[8];
extern const char *IP_PHYS_ADDRS[8];
extern const uint32_t DEFAULT_DMA_BUFS[8];

extern pthread_mutex_t    g_udp_mutex;
extern int                g_udp_sock;
extern int                g_cmd_sock;
extern struct sockaddr_in g_udp_dest;
extern uint16_t           g_cmd_port;
extern volatile int       g_threads_running;
extern volatile int       g_pipeline_running;

/* Global parameters */
extern volatile double   g_threshold_mv;
extern volatile uint32_t g_pdt;
extern volatile uint32_t g_hdt;
extern volatile uint32_t g_hlt;
extern volatile uint32_t g_pretrig;

/* Per-channel parameters */
extern volatile double   g_ch_threshold_mv[8];
extern volatile uint32_t g_ch_pdt[8];
extern volatile uint32_t g_ch_hdt[8];
extern volatile uint32_t g_ch_hlt[8];
extern volatile uint32_t g_ch_pretrig[8];

extern volatile double   g_sample_period_ns;
extern volatile uint32_t g_events_recorded;
extern volatile uint32_t g_seq_num;
extern char              g_client_id[64];
extern char              g_session_id[64];
extern volatile uint32_t *g_ip_regs[8];
extern uint32_t          g_poll_timeout_us;
extern int               g_verbose;

#endif /* EVENT_DMA_CAPTURE_H */
