#ifndef AD9361_STATS_H
#define AD9361_STATS_H

#include <stdint.h>

struct dir_stats {
    volatile uint64_t bytes;    // cumulative bytes transferred
    volatile uint64_t overrun;  // RX: lost samples; TX: underruns (unused today)
    volatile uint32_t buf_used; // current ring fill
    uint32_t buf_size;          // set once when direction starts
};

extern struct dir_stats g_rx_stats;
extern struct dir_stats g_tx_stats;

void *status_thread(void *unused);

#endif
