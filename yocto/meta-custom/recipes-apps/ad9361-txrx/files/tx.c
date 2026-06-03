#define _GNU_SOURCE
#include "tx.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "net.h"
#include "stats.h"

struct tx_session {
    struct driver *drv;
    int16_t *map;
    uint32_t map_size;
    struct app_ctx *ctx;
};

// Advance TX write pointer and bump producer-side stats.
static int tx_put_block(struct driver *drv, uint32_t wr) {
    if (driver_tx_put_block(drv, wr) < 0)
        return -1;
    g_tx_stats.bytes += drv->block_size;
    return 0;
}

static int tx_tcp_session(int client, void *user) {
    struct tx_session *s = user;
    uint32_t block_size = s->drv->block_size;
    uint32_t wr = 0;

    if (s->ctx->cli->rx_mode != MODE_NONE) {
        pthread_mutex_lock(&s->ctx->start_mutex);
        while (!s->ctx->rx_session_active)
            pthread_cond_wait(&s->ctx->start_cond, &s->ctx->start_mutex);
        pthread_mutex_unlock(&s->ctx->start_mutex);
    }

    uint32_t prefill_bytes = (uint32_t)TXRX_PREFILL_SAMPLES * SAMPLE_SIZE;
    uint32_t prefill_blocks = (prefill_bytes + block_size - 1) / block_size;
    fprintf(stderr, "TX: prefilling %u blocks (%u samples)\n",
            prefill_blocks, prefill_blocks * block_size / SAMPLE_SIZE);
    for (uint32_t i = 0; i < prefill_blocks; i++) {
        memset((uint8_t *)s->map + wr, 0, block_size);
        wr = (wr + block_size) % s->map_size;
        if (driver_tx_put_block(s->drv, wr) < 0)
            return -1;
    }

    if (driver_enable(s->drv) < 0)
        return -1;

    while (1) {
        if (tcp_recv_full(client, (uint8_t *)s->map + wr, block_size) < 0)
            return -1;
        wr = (wr + block_size) % s->map_size;
        if (tx_put_block(s->drv, wr) < 0)
            return -1;
    }
}

static int tx_task(struct app_ctx *ctx) {
    const struct cli_cfg *cli = ctx->cli;

    uint32_t effective = ctx->drv.tx_buf_size;
    if (cli->tx_depth_msamples > 0) {
        effective = (uint32_t)(cli->tx_depth_msamples * 1000000.0) * SAMPLE_SIZE;
        effective =
            ((effective + ctx->drv.block_size - 1) / ctx->drv.block_size) * ctx->drv.block_size;
        if (effective > ctx->drv.tx_buf_size)
            effective = ctx->drv.tx_buf_size;
    }
    fprintf(stderr, "TX effective: %u KB (max %u KB)\n", effective / 1024,
            ctx->drv.tx_buf_size / 1024);

    int16_t *map = driver_tx_mmap(&ctx->drv, effective);
    if (!map) {
        driver_close(&ctx->drv);
        return 1;
    }
    g_tx_stats.buf_size = effective;

    if (cli->tx_mode == MODE_TCP) {
        int client = tcp_accept(ctx->tx_server_fd, 0, SOCK_BUF_BYTES, 0, "TX");
        if (client >= 0) {
            struct tx_session s = {.drv = &ctx->drv, .map = map, .map_size = effective, .ctx = ctx};
            tx_tcp_session(client, &s);
            close(client);
            fprintf(stderr, "TX client disconnected\n");
        }
    } else {
        fprintf(stderr, "--tx-udp: not yet implemented\n");
    }

    driver_tx_munmap(map, effective);
    // Close the driver to signal the RX thread (if combined) that this session is done.
    driver_close(&ctx->drv);
    return 0;
}

void *tx_thread(void *arg) { return (void *)(intptr_t)tx_task(arg); }
