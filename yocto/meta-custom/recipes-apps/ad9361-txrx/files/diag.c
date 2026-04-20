#define _GNU_SOURCE
#include "diag.h"

#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "prbs.h"
#include "stats.h"

#define TONE_PERIOD 64
#define TONE_AMPLITUDE 0x7FF0

struct tx_feeder_thread_ctx {
    struct driver *drv;
    int16_t *tx_map;
    uint32_t tx_buf_size;
    int prbs;
};

static void tx_generate_tone(int16_t *buf, uint32_t num_samples) {
    for (int i = 0; i < TONE_PERIOD; i++) {
        double phase = 2.0 * M_PI * i / TONE_PERIOD;
        buf[i * 2 + 0] = (int16_t)(TONE_AMPLITUDE * cos(phase));
        buf[i * 2 + 1] = (int16_t)(TONE_AMPLITUDE * sin(phase));
    }
    uint32_t period_bytes = TONE_PERIOD * SAMPLE_SIZE;
    uint32_t total_bytes = num_samples * SAMPLE_SIZE;
    for (uint32_t off = period_bytes; off < total_bytes; off += period_bytes) {
        uint32_t chunk = total_bytes - off;
        if (chunk > period_bytes)
            chunk = period_bytes;
        memcpy((uint8_t *)buf + off, buf, chunk);
    }
}

// Feeder thread: refills the TX ring (PRBS or pre-filled tone) and advances wr.
static void *tx_feeder_thread(void *arg) {
    struct tx_feeder_thread_ctx *ctx = arg;
    uint32_t wr = 0;
    uint32_t prbs_p = 0;
    uint32_t block_size = ctx->drv->block_size;
    uint32_t buf_size = ctx->tx_buf_size;

    while (1) {
        if (ctx->prbs) {
            int16_t *dst = (int16_t *)((uint8_t *)ctx->tx_map + wr);
            prbs_fill_block(dst, block_size / SAMPLE_SIZE, &prbs_p);
        }
        wr = (wr + block_size) % buf_size;
        if (driver_tx_put_block(ctx->drv, wr) < 0)
            break;
        g_tx_stats.bytes += block_size;
    }
    return NULL;
}

int diag_test(struct app_ctx *ctx) {
    uint8_t *map = driver_rx_mmap(&ctx->drv);
    if (!map)
        return 1;

    struct rx_read r;
    while (1) {
        usleep(100000);

        if (driver_rx_get_block(&ctx->drv, &r) < 0) {
            driver_rx_munmap(&ctx->drv, map);
            return 1;
        }

        uint32_t used = ringbuf_used(r.rd, r.hw_wr, ctx->drv.rx_buf_size);

        printf("rd=0x%08x hw_wr=0x%08x used=%u (%u%%)\n", r.rd, r.hw_wr, used,
               used / (ctx->drv.rx_buf_size / 100));

        uint32_t *m = (uint32_t *)map;
        if (r.hw_wr != r.rd)
            printf("first word: 0x%08x\n", m[r.rd / 4]);
        else
            printf("no new data\n");
    }

    driver_rx_munmap(&ctx->drv, map);
    return 0;
}

int diag_membench(struct app_ctx *ctx, int loops) {
    uint8_t *map = driver_rx_mmap(&ctx->drv);
    if (!map)
        return 1;

    const size_t block_size = 64 * 1024;
    uint8_t *dst = malloc(block_size);
    if (!dst) {
        perror("malloc");
        driver_rx_munmap(&ctx->drv, map);
        return 1;
    }

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    uint64_t total_bytes = 0;
    for (int i = 0; i < loops; i++) {
        for (size_t off = 0; off < ctx->drv.rx_buf_size; off += block_size) {
            memcpy(dst, map + off, block_size);
            __asm__ volatile("" ::: "memory");
        }
        total_bytes += ctx->drv.rx_buf_size;
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);

    double elapsed = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) * 1e-9;
    double mb = (double)total_bytes / (1024.0 * 1024.0);
    printf("Copied %.0f MB in %.3f s => %.1f MB/s\n", mb, elapsed, mb / elapsed);

    free(dst);
    driver_rx_munmap(&ctx->drv, map);
    return 0;
}

int diag_loopback(struct app_ctx *ctx) {
    uint8_t *rx_map = driver_rx_mmap(&ctx->drv);
    if (!rx_map)
        return 1;

    int16_t *tx_map = driver_tx_mmap(&ctx->drv, ctx->drv.tx_buf_size);
    if (!tx_map) {
        driver_rx_munmap(&ctx->drv, rx_map);
        return 1;
    }

    tx_generate_tone(tx_map, ctx->drv.tx_buf_size / SAMPLE_SIZE);

    struct tx_feeder_thread_ctx tx_ctx = {
        .drv = &ctx->drv, .tx_map = tx_map, .tx_buf_size = ctx->drv.tx_buf_size, .prbs = 0};
    pthread_t tx_thr;
    pthread_create(&tx_thr, NULL, tx_feeder_thread, &tx_ctx);

    fprintf(stderr, "Loopback running...\n");

    struct rx_read r;
    uint32_t count = 0;
    while (1) {
        if (driver_rx_get_block(&ctx->drv, &r) < 0)
            break;

        int16_t *samples = (int16_t *)(rx_map + r.rd);
        if (count % 16 == 0) {
            printf("blk %u rd=0x%08x wr=0x%08x lost=%u | ", count, r.rd, r.hw_wr, r.lost_bytes);
            for (int i = 0; i < 8; i++)
                printf("(%6d,%6d) ", samples[i * 2], samples[i * 2 + 1]);
            printf("\n");
        }
        count++;
    }

    driver_tx_munmap(tx_map, ctx->drv.tx_buf_size);
    driver_rx_munmap(&ctx->drv, rx_map);
    return 0;
}

int diag_prbs(struct app_ctx *ctx) {
    prbs_init();

    uint8_t *rx_map = driver_rx_mmap(&ctx->drv);
    if (!rx_map)
        return 1;

    int16_t *tx_map = driver_tx_mmap(&ctx->drv, ctx->drv.tx_buf_size);
    if (!tx_map) {
        driver_rx_munmap(&ctx->drv, rx_map);
        return 1;
    }

    struct tx_feeder_thread_ctx tx_ctx = {
        .drv = &ctx->drv,
        .tx_map = tx_map,
        .tx_buf_size = ctx->drv.tx_buf_size,
        .prbs = 1,
    };
    pthread_t tx_thr;
    pthread_create(&tx_thr, NULL, tx_feeder_thread, &tx_ctx);

    fprintf(stderr, "PRBS test running...\n");

    struct rx_read r;
    int pos = -1;
    uint64_t errors = 0, total_errors = 0, samples = 0;
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    while (1) {
        if (driver_rx_get_block(&ctx->drv, &r) < 0)
            break;

        int16_t *blk = (int16_t *)(rx_map + r.rd);
        uint32_t num_samples = ctx->drv.block_size / SAMPLE_SIZE;

        if (pos < 0) {
            uint16_t rx_i = (uint16_t)blk[0] >> 4;
            uint16_t rx_q = (uint16_t)blk[1] >> 4;
            uint16_t st = prbs_state_from_iq(rx_i, rx_q);
            if (st != 0)
                pos = g_prbs_pos[st];
            else
                continue;
        }

        uint32_t s = 0;
        uint32_t p = pos;
        while (s < num_samples) {
            uint32_t chunk = PRBS_LEN - p;
            if (chunk > num_samples - s)
                chunk = num_samples - s;
            if (memcmp(&blk[s * 2], &g_prbs_lut[p], chunk * SAMPLE_SIZE) == 0) {
                s += chunk;
                p = (p + chunk) % PRBS_LEN;
            } else {
                uint32_t lo = 0, hi = chunk;
                while (hi - lo > 1) {
                    uint32_t mid = lo + (hi - lo) / 2;
                    if (memcmp(&blk[(s + lo) * 2], &g_prbs_lut[p + lo], (mid - lo) * SAMPLE_SIZE) ==
                        0)
                        lo = mid;
                    else
                        hi = mid;
                }
                uint32_t i = lo;
                uint16_t rx_i = (uint16_t)blk[(s + i) * 2] >> 4;
                if (errors == 0) {
                    uint16_t exp_i = (uint16_t)g_prbs_lut[p + i].i >> 4;
                    fprintf(stderr, "ERR at pos=%u: got I=%03x exp I=%03x\n", p + i, rx_i, exp_i);
                }
                errors++;

                uint32_t behind = ringbuf_used(r.rd, r.hw_wr, ctx->drv.rx_buf_size);
                while (behind > ctx->drv.block_size * 2) {
                    if (driver_rx_get_block(&ctx->drv, &r) < 0)
                        goto out;
                    behind = ringbuf_used(r.rd, r.hw_wr, ctx->drv.rx_buf_size);
                }
                p = -1;
                goto next_block;
            }
        }
    next_block:
        pos = p;
        samples += num_samples;

        struct timespec t1;
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double elapsed = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) * 1e-9;
        if (elapsed >= 1.0) {
            total_errors += errors;
            double msps = (double)samples / elapsed / 1e6;
            fprintf(stderr, "PRBS: %.3f MSPS  errors=%llu  total=%llu\n", msps,
                    (unsigned long long)errors, (unsigned long long)total_errors);
            errors = 0;
            samples = 0;
            t0 = t1;
        }
    }

out:
    driver_tx_munmap(tx_map, ctx->drv.tx_buf_size);
    driver_rx_munmap(&ctx->drv, rx_map);
    return 0;
}
