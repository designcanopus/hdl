#ifndef EVENT_DMA_UDP_H
#define EVENT_DMA_UDP_H

#include "event_dma_capture.h"
#include "event_dma_hw.h"

/* Networking function prototypes */
void  iso8601_now(char *buf, size_t buflen);

void  send_session_ack(int sock, const struct sockaddr_in *dest,
                       const char *event, int ok,
                       const char *client_id, const char *session_id);

void  send_status_packet(int sock, const struct sockaddr_in *dest);

void *command_listener_thread(void *arg);

void *status_broadcast_thread(void *arg);

int   send_event_udp(const uint32_t *hdr32, uint32_t n_samples,
                     int channel, uint32_t event_id, uint32_t seq_num,
                     double sample_period_ns, double peak_mv, double peak_freq_khz,
                     uint64_t energy, uint16_t ae_count, uint32_t duration,
                     uint32_t pretrig_samples, uint32_t pdt_samples,
                     uint32_t hdt_samples, uint32_t hlt_samples);

#endif /* EVENT_DMA_UDP_H */
