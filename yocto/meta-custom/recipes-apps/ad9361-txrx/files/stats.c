#include "stats.h"

#include "driver.h" // SAMPLE_SIZE

#include <stdio.h>
#include <time.h>
#include <unistd.h>

struct dir_stats g_rx_stats;
struct dir_stats g_tx_stats;

// Render one direction's stats line into out; empty string if direction inactive.
static void format_dir(char *out, size_t cap, const char *label, const struct dir_stats *s,
                       uint64_t prev_bytes, uint64_t prev_overrun, double elapsed) {
    if (!s->buf_size) {
        out[0] = '\0';
        return;
    }
    uint64_t b = s->bytes;
    double mbps = (double)(b - prev_bytes) / elapsed / (1024.0 * 1024.0);
    double msps = (double)(b - prev_bytes) / SAMPLE_SIZE / elapsed / 1e6;
    uint32_t buf_pct = s->buf_used / (s->buf_size / 100);
    uint64_t lost = s->overrun - prev_overrun;
    snprintf(out, cap, "%s %.1f MB/s %.2f MSPS buf=%u%% lost=%llu", label, mbps, msps, buf_pct,
             (unsigned long long)lost);
}

// Print a per-second summary of RX/TX rate and ring health to stderr.
void *status_thread(void *unused) {
    (void)unused;
    uint64_t prev_rx_b = 0, prev_rx_o = 0;
    uint64_t prev_tx_b = 0, prev_tx_o = 0;
    struct timespec last;
    clock_gettime(CLOCK_MONOTONIC, &last);

    while (1) {
        usleep(1000000);
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double elapsed = (now.tv_sec - last.tv_sec) + (now.tv_nsec - last.tv_nsec) * 1e-9;

        char rx_line[128], tx_line[128];
        format_dir(rx_line, sizeof(rx_line), "RX", &g_rx_stats, prev_rx_b, prev_rx_o, elapsed);
        format_dir(tx_line, sizeof(tx_line), "TX", &g_tx_stats, prev_tx_b, prev_tx_o, elapsed);

        if (rx_line[0] && tx_line[0])
            fprintf(stderr, "%s | %s\n", rx_line, tx_line);
        else if (rx_line[0])
            fprintf(stderr, "%s\n", rx_line);
        else if (tx_line[0])
            fprintf(stderr, "%s\n", tx_line);

        prev_rx_b = g_rx_stats.bytes;
        prev_rx_o = g_rx_stats.overrun;
        prev_tx_b = g_tx_stats.bytes;
        prev_tx_o = g_tx_stats.overrun;
        last = now;
    }
    return NULL;
}
