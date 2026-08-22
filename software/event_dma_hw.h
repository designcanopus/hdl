#ifndef EVENT_DMA_HW_H
#define EVENT_DMA_HW_H

#include "event_dma_capture.h"

/* Register access helper inlines */
static inline void write_reg(volatile uint32_t *base, uint32_t off, uint32_t val) {
    base[off / 4] = val;
}

static inline uint32_t read_reg(volatile uint32_t *base, uint32_t off) {
    return base[off / 4];
}

/*
 * write_reg_safe() — Write a register and immediately read it back.
 *
 * WHY THIS IS NEEDED:
 * Event_Capture_AXIL.v only accepts a new AXI write when axi_bvalid == 0:
 *   if (s_axi_awvalid && s_axi_wvalid && !axi_bvalid) ...
 * However s_axi_awready and s_axi_wready are permanently tied HIGH (1'b1),
 * so the ARM AXI master fires consecutive writes without stalling.
 * Writes 2-5 arrive while axi_bvalid is still 1 from write 1 → silently dropped.
 *
 * The read-back forces the AXI interconnect to wait for the write response
 * (bvalid/bready handshake) before issuing the next write, ensuring every
 * register write is accepted by the IP core.
 */
static inline uint32_t write_reg_safe(volatile uint32_t *base, uint32_t off, uint32_t val) {
    base[off / 4] = val;
    __sync_synchronize();           /* full memory barrier — flush store buffer */
    return base[off / 4];           /* read-back: stalls until write response arrives */
}

/* Hardware access function prototypes */
int           open_uio_by_name(const char *target_addr, const char *alt_name);
unsigned long read_uio_map_val(int fd, int map_idx, const char *entry, unsigned long def_val);
int           wait_dma_done(volatile uint32_t *dma_regs, uint32_t xfer_id);
void          enable_adc_sampling(void);

#endif /* EVENT_DMA_HW_H */
