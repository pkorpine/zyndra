#define _GNU_SOURCE
#include "tx.h"

#include <stdint.h>
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>

#include "net.h"
#include "stats.h"

struct tx_session {
    struct driver *drv;
    int16_t *map;
    uint32_t map_size;
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
    if (!map)
        return 1;

    g_tx_stats.buf_size = effective;

    int ret;
    if (cli->tx_mode == MODE_TCP) {
        struct tx_session s = {.drv = &ctx->drv, .map = map, .map_size = effective};
        ret = tcp_serve(cli->tx_port, 0, SOCK_BUF_BYTES, 0, "TX", tx_tcp_session, &s);
    } else {
        fprintf(stderr, "--tx-udp: not yet implemented\n");
        ret = 1;
    }

    driver_tx_munmap(map, effective);
    return ret;
}

void *tx_thread(void *arg) { return (void *)(intptr_t)tx_task(arg); }
