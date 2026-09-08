/*
 * event_dma_udp.c – Networking, Visualizer IPC & Telemetry implementation
 * =========================================================================
 * Handles UDP session handshake, Port 8081 command listener server,
 * Port 8080 periodic status broadcaster, ISO-8601 timestamp formatting,
 * and JSON/waveform UDP packet serialization.
 */

#include "event_dma_udp.h"

/* ISO-8601 UTC timestamp string */
void iso8601_now(char *buf, size_t buflen)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm_utc;
    gmtime_r(&tv.tv_sec, &tm_utc);
    size_t n = strftime(buf, buflen, "%Y-%m-%dT%H:%M:%S", &tm_utc);
    if (n + 1 < buflen) {
        snprintf(buf + n, buflen - n, ".%06ldZ", (long)tv.tv_usec);
    }
}

/* Helper to parse JSON numbers robustly */
static int parse_json_num(const char *buf, const char *key, double *val_out)
{
    const char *p = strstr(buf, key);
    if (!p) return 0;
    p += strlen(key);
    while (*p && (*p == ' ' || *p == ':' || *p == '"' || *p == '=')) p++;
    if (*p == '\0') return 0;
    char *endp = NULL;
    double v = strtod(p, &endp);
    if (endp == p) return 0;
    *val_out = v;
    return 1;
}

/* UDP session acknowledgment for ae_visualizer */
void send_session_ack(int sock, const struct sockaddr_in *dest,
                      const char *event, int ok,
                      const char *client_id, const char *session_id)
{
    if (sock < 0 || !dest) return;
    char payload[256];
    snprintf(payload, sizeof(payload),
             "session|{\"ok\":%s,\"event\":\"%s\",\"client_id\":\"%s\",\"session_id\":\"%s\",\"server_ts\":%.3f}",
             ok ? "true" : "false", event, client_id, session_id, (double)time(NULL));
    sendto(sock, payload, strlen(payload), 0, (const struct sockaddr *)dest, sizeof(*dest));
}

/* Pipeline status packet broadcaster */
void send_status_packet(int sock, const struct sockaddr_in *dest)
{
    if (sock < 0 || !dest) return;
    char payload[450];
    double trig_mv    = g_threshold_mv;
    double hdt_us     = (double)g_hdt * g_sample_period_ns / 1000.0;
    double hlt_us     = (double)g_hlt * g_sample_period_ns / 1000.0;
    double pdt_us     = (double)g_pdt * g_sample_period_ns / 1000.0;
    double pretrig_us = (double)g_pretrig * g_sample_period_ns / 1000.0;

    double hdt_ms     = hdt_us / 1000.0;
    double hlt_ms     = hlt_us / 1000.0;
    double pdt_ms     = pdt_us / 1000.0;
    double pretrig_ms = pretrig_us / 1000.0;

    snprintf(payload, sizeof(payload),
             "status|{"
             "\"capture_drops\":0,\"recorder_queue_depth\":0,\"recorder_healthy\":true,"
             "\"events_recorded\":%u,\"trigger_mv\":%.2f,\"release_mv\":%.2f,"
             "\"hdt_us\":%.2f,\"hlt_us\":%.2f,\"pdt_us\":%.2f,\"pre_trigger_us\":%.2f,"
             "\"hdt_ms\":%.4f,\"hlt_ms\":%.4f,\"pdt_ms\":%.4f,\"pre_trigger_ms\":%.4f,"
             "\"max_event_us\":200.0,\"state\":\"%s\","
             "\"rate_capture_hz\":0.0,\"rate_processing_hz\":0.0,"
             "\"rate_recording_hz\":0.0,\"rate_interface_hz\":0.0"
             "}",
             g_events_recorded, trig_mv, trig_mv * 0.5,
             hdt_us, hlt_us, pdt_us, pretrig_us,
             hdt_ms, hlt_ms, pdt_ms, pretrig_ms,
             g_pipeline_running ? "RUNNING" : "STOPPED");

    sendto(sock, payload, strlen(payload), 0, (const struct sockaddr *)dest, sizeof(*dest));
}

/* Command Server Thread (Handles ae_visualizer registration on Port 8081) */
void *command_listener_thread(void *arg)
{
    (void)arg;
    g_cmd_sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (g_cmd_sock < 0) return NULL;

    int opt = 1;
    setsockopt(g_cmd_sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct timeval tv = {.tv_sec = 0, .tv_usec = 200000};
    setsockopt(g_cmd_sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    struct sockaddr_in bind_addr;
    memset(&bind_addr, 0, sizeof(bind_addr));
    bind_addr.sin_family      = AF_INET;
    bind_addr.sin_port        = htons(g_cmd_port);
    bind_addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(g_cmd_sock, (struct sockaddr *)&bind_addr, sizeof(bind_addr)) < 0) {
        close(g_cmd_sock);
        g_cmd_sock = -1;
        return NULL;
    }

    printf("Command server running on UDP 0.0.0.0:%u\n", g_cmd_port);

    char buf[2048];
    struct sockaddr_in client_addr;
    socklen_t addr_len;

    while (g_threads_running) {
        addr_len = sizeof(client_addr);
        ssize_t n = recvfrom(g_cmd_sock, buf, sizeof(buf) - 1, 0,
                             (struct sockaddr *)&client_addr, &addr_len);
        if (n <= 0) continue;
        buf[n] = '\0';

        char cid[64] = "";
        char *cid_ptr = strstr(buf, "\"client_id\"");
        if (cid_ptr) sscanf(cid_ptr, "\"client_id\"%*[: ]\"%63[^\"]\"", cid);
        if (cid[0] == '\0') snprintf(cid, sizeof(cid), "%s", g_client_id);

        int event_port = DEFAULT_DEST_PORT;
        char *port_ptr = strstr(buf, "\"event_port\"");
        if (port_ptr) sscanf(port_ptr, "\"event_port\"%*[: ]%d", &event_port);

        struct sockaddr_in ack_dest = client_addr;
        if (event_port > 0) ack_dest.sin_port = htons((uint16_t)event_port);

        if (strstr(buf, "\"register\"") || strstr(buf, "\"connect\"")) {
            pthread_mutex_lock(&g_udp_mutex);
            snprintf(g_client_id, sizeof(g_client_id), "%s", cid);
            g_udp_dest = ack_dest;
            pthread_mutex_unlock(&g_udp_mutex);

            printf("Registered visualizer client %s (event_port: %d)\n", cid, event_port);
            send_session_ack(g_cmd_sock, &client_addr, "registered", 1, g_client_id, g_session_id);
            send_status_packet(g_cmd_sock, &ack_dest);
        } else if (strstr(buf, "\"heartbeat\"")) {
            send_session_ack(g_cmd_sock, &client_addr, "heartbeat_ok", 1, cid, g_session_id);
        } else if (strstr(buf, "\"start\"")) {
            g_pipeline_running = 1;
            send_status_packet(g_cmd_sock, &ack_dest);
        } else if (strstr(buf, "\"stop\"")) {
            g_pipeline_running = 0;
            send_status_packet(g_cmd_sock, &ack_dest);
        } else if (strstr(buf, "\"set_thresholds\"") || strstr(buf, "\"set_settings\"")) {
            double trig_mv = 0.0;
            if (parse_json_num(buf, "\"trigger_mv\"", &trig_mv) ||
                parse_json_num(buf, "\"threshold_mv\"", &trig_mv) ||
                parse_json_num(buf, "\"threshold\"", &trig_mv)) {
                if (trig_mv < 0.0)   trig_mv = 0.0;
                if (trig_mv > 100.0) trig_mv = 100.0;
                g_threshold_mv = trig_mv;
                int32_t thresh_lsb = (int32_t)(g_threshold_mv * (ADC_CODES / ADC_FULL_SCALE_MV));
                for (int ch = 0; ch < 8; ch++) {
                    g_ch_threshold_mv[ch] = g_threshold_mv;
                    if (g_ip_regs[ch]) write_reg_safe(g_ip_regs[ch], REG_IP_THRESHOLD, (uint32_t)thresh_lsb);
                }
            }

            double pdt_val = 0.0;
            if (parse_json_num(buf, "\"pdt_ms\"", &pdt_val)) {
                g_pdt = (uint32_t)(pdt_val * 1e6 / g_sample_period_ns);
            } else if (parse_json_num(buf, "\"pdt_us\"", &pdt_val)) {
                g_pdt = (uint32_t)(pdt_val * 1000.0 / g_sample_period_ns);
            } else if (parse_json_num(buf, "\"pdt_samples\"", &pdt_val) || parse_json_num(buf, "\"pdt\"", &pdt_val)) {
                g_pdt = (uint32_t)pdt_val;
            }
            for (int ch = 0; ch < 8; ch++) {
                g_ch_pdt[ch] = g_pdt;
                if (g_ip_regs[ch]) write_reg_safe(g_ip_regs[ch], REG_IP_PDT, g_pdt);
            }

            double hdt_val = 0.0;
            if (parse_json_num(buf, "\"hdt_ms\"", &hdt_val)) {
                g_hdt = (uint32_t)(hdt_val * 1e6 / g_sample_period_ns);
            } else if (parse_json_num(buf, "\"hdt_us\"", &hdt_val)) {
                g_hdt = (uint32_t)(hdt_val * 1000.0 / g_sample_period_ns);
            } else if (parse_json_num(buf, "\"hdt_samples\"", &hdt_val) || parse_json_num(buf, "\"hdt\"", &hdt_val)) {
                g_hdt = (uint32_t)hdt_val;
            }
            for (int ch = 0; ch < 8; ch++) {
                g_ch_hdt[ch] = g_hdt;
                if (g_ip_regs[ch]) write_reg_safe(g_ip_regs[ch], REG_IP_HDT, g_hdt);
            }

            double hlt_val = 0.0;
            if (parse_json_num(buf, "\"hlt_ms\"", &hlt_val)) {
                g_hlt = (uint32_t)(hlt_val * 1e6 / g_sample_period_ns);
            } else if (parse_json_num(buf, "\"hlt_us\"", &hlt_val)) {
                g_hlt = (uint32_t)(hlt_val * 1000.0 / g_sample_period_ns);
            } else if (parse_json_num(buf, "\"hlt_samples\"", &hlt_val) || parse_json_num(buf, "\"hlt\"", &hlt_val)) {
                g_hlt = (uint32_t)hlt_val;
            }
            for (int ch = 0; ch < 8; ch++) {
                g_ch_hlt[ch] = g_hlt;
                if (g_ip_regs[ch]) write_reg_safe(g_ip_regs[ch], REG_IP_HLT, g_hlt);
            }

            double pretrig_val = 0.0;
            if (parse_json_num(buf, "\"pre_trigger_ms\"", &pretrig_val)) {
                g_pretrig = (uint32_t)(pretrig_val * 1e6 / g_sample_period_ns);
            } else if (parse_json_num(buf, "\"pre_trigger_us\"", &pretrig_val)) {
                g_pretrig = (uint32_t)(pretrig_val * 1000.0 / g_sample_period_ns);
            } else if (parse_json_num(buf, "\"pretrig\"", &pretrig_val) || parse_json_num(buf, "\"pre_trigger\"", &pretrig_val)) {
                g_pretrig = (uint32_t)pretrig_val;
            }
            for (int ch = 0; ch < 8; ch++) {
                g_ch_pretrig[ch] = g_pretrig;
                if (g_ip_regs[ch]) write_reg_safe(g_ip_regs[ch], REG_IP_PRETRIG, g_pretrig);
            }

            send_status_packet(g_cmd_sock, &ack_dest);
        }
    }

    close(g_cmd_sock);
    g_cmd_sock = -1;
    return NULL;
}

/* Status Broadcaster Thread (Periodically notifies visualizer) */
void *status_broadcast_thread(void *arg)
{
    (void)arg;
    while (g_threads_running) {
        for (int i = 0; i < 5 && g_threads_running; i++) usleep(100000);
        if (!g_threads_running) break;

        pthread_mutex_lock(&g_udp_mutex);
        if (g_cmd_sock >= 0 && g_udp_dest.sin_family == AF_INET) {
            send_status_packet(g_cmd_sock, &g_udp_dest);
        }
        pthread_mutex_unlock(&g_udp_mutex);
    }
    return NULL;
}

/* UDP Event Transmission */
int send_event_udp(const uint32_t *hdr32, uint32_t n_samples,
                   int channel, uint32_t event_id, uint32_t seq_num,
                   double sample_period_ns, double peak_mv, double peak_freq_khz,
                   uint64_t energy, uint16_t ae_count, uint32_t duration,
                   uint32_t pretrig_samples, uint32_t pdt_samples,
                   uint32_t hdt_samples, uint32_t hlt_samples)
{
    if (g_udp_sock < 0) return 0;

    char ts[40];
    iso8601_now(ts, sizeof(ts));
    double duration_us = duration * sample_period_ns / 1000.0;
    double pre_trig_us = pretrig_samples * sample_period_ns / 1000.0;
    double pdt_us      = pdt_samples * sample_period_ns / 1000.0;
    double hdt_us      = hdt_samples * sample_period_ns / 1000.0;
    double hlt_us      = hlt_samples * sample_period_ns / 1000.0;

    double duration_ms = duration_us / 1000.0;
    double pre_trig_ms = pre_trig_us / 1000.0;
    double pdt_ms      = pdt_us / 1000.0;
    double hdt_ms      = hdt_us / 1000.0;
    double hlt_ms      = hlt_us / 1000.0;

    uint32_t sample_rate_hz = (uint32_t)(1e9 / sample_period_ns);
    double thresh_mv = g_ch_threshold_mv[channel];

    /* Stream full HDL capture (up to 16000 samples / 64 KB float array to fit UDP socket) */
    uint32_t udp_samples = (n_samples > 16000) ? 16000 : n_samples;

    char json[850];
    int json_len = snprintf(json, sizeof(json),
        "{"
        "\"type\":\"ae_event\","
        "\"seq_num\":%u,"
        "\"event_id\":\"%u\","
        "\"trigger_channel\":%d,"
        "\"start_sample\":0,"
        "\"end_sample\":%u,"
        "\"timestamp\":\"%s\","
        "\"flags\":0,"
        "\"sample_rate_hz\":%u,"
        "\"pre_trigger_us\":%.2f,"
        "\"pdt_us\":%.2f,"
        "\"hdt_us\":%.2f,"
        "\"hlt_us\":%.2f,"
        "\"pre_trigger_ms\":%.4f,"
        "\"pdt_ms\":%.4f,"
        "\"hdt_ms\":%.4f,"
        "\"hlt_ms\":%.4f,"
        "\"threshold\":%.2f,"
        "\"threshold_release\":%.2f,"
        "\"features\":{"
        "\"peak_amplitude\":%.4f,"
        "\"peak_frequency_khz\":%.2f,"
        "\"energy\":%llu,"
        "\"duration_us\":%.3f,"
        "\"duration_ms\":%.4f,"
        "\"counts\":%u,"
        "\"trigger_offset\":%u"
        "}"
        "}",
        seq_num, event_id, channel, udp_samples, ts,
        sample_rate_hz, pre_trig_us, pdt_us, hdt_us, hlt_us,
        pre_trig_ms, pdt_ms, hdt_ms, hlt_ms,
        thresh_mv, thresh_mv * 0.5,
        peak_mv, peak_freq_khz, (unsigned long long)energy, duration_us, duration_ms, ae_count,
        pretrig_samples);

    if (json_len < 0 || (size_t)json_len >= sizeof(json)) return -1;

    /* Waveform samples start immediately after 64-byte HDL header */
    const int16_t *samples = (const int16_t *)((const char *)hdr32 + HDL_HEADER_BYTES);

    float *wf = malloc((size_t)udp_samples * sizeof(float));
    if (!wf) return -1;
    for (uint32_t i = 0; i < udp_samples; i++) {
        wf[i] = (float)(samples[i] * (ADC_FULL_SCALE_MV / ADC_CODES));
    }

    size_t packet_len = UDP_HEADER_LEN + 4 + (size_t)json_len + (size_t)udp_samples * sizeof(float);
    uint8_t *packet = malloc(packet_len);
    if (!packet) { free(wf); return -1; }

    memcpy(packet, UDP_HEADER_TAG, UDP_HEADER_LEN);
    uint32_t json_len_le = (uint32_t)json_len;
    memcpy(packet + UDP_HEADER_LEN, &json_len_le, 4);
    memcpy(packet + UDP_HEADER_LEN + 4, json, (size_t)json_len);
    memcpy(packet + UDP_HEADER_LEN + 4 + json_len, wf, (size_t)udp_samples * sizeof(float));

    pthread_mutex_lock(&g_udp_mutex);
    struct sockaddr_in dest = g_udp_dest;
    pthread_mutex_unlock(&g_udp_mutex);

    ssize_t sent = sendto(g_udp_sock, packet, packet_len, 0,
                          (struct sockaddr *)&dest, sizeof(dest));

    if (g_verbose && sent > 0) {
        printf("UDP: sent event_combined| CH%d seq=%u event_id=%u (%zu bytes, %u samples)\n",
               channel, seq_num, event_id, packet_len, udp_samples);
    }

    /* Fallback: if binary datagram send failed, send plain JSON metadata so features are not lost */
    if (sent <= 0) {
        char meta_packet[1024];
        int meta_len = snprintf(meta_packet, sizeof(meta_packet), "event_metadata|%s", json);
        if (meta_len > 0) {
            sent = sendto(g_udp_sock, meta_packet, (size_t)meta_len, 0,
                          (struct sockaddr *)&dest, sizeof(dest));
        }
    }

    if (sent > 0) g_events_recorded++;
    free(wf);
    free(packet);
    return (sent > 0) ? 0 : -1;
}
