#define _GNU_SOURCE
#include "rx.h"

#include <arpa/inet.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "net.h"
#include "stats.h"

struct rx_session {
    struct driver *drv;
    const uint8_t *map;
    struct app_ctx *ctx;
};

// Fetch RX pointers and update consumer-side stats (used + overrun).
static int rx_get_block(struct driver *drv, struct rx_read *r) {
    if (driver_rx_get_block(drv, r) < 0)
        return -1;
    g_rx_stats.buf_used = ringbuf_used(r->rd, r->hw_wr, drv->rx_buf_size);
    g_rx_stats.overrun += r->lost_bytes;
    return 0;
}

static int rx_tcp_session(int client, void *user) {
    struct rx_session *s = user;
    struct rx_read r;
    uint32_t block_size = s->drv->block_size;

    if (s->ctx->cli->tx_mode != MODE_NONE) {
        pthread_mutex_lock(&s->ctx->start_mutex);
        s->ctx->rx_session_active = true;
        pthread_cond_signal(&s->ctx->start_cond);
        pthread_mutex_unlock(&s->ctx->start_mutex);
    } else {
        if (driver_enable(s->drv) < 0)
            return -1;
    }

    uint32_t prefill_bytes = (uint32_t)TXRX_PREFILL_SAMPLES * SAMPLE_SIZE;
    uint32_t drop_blocks = (prefill_bytes + block_size - 1) / block_size;
    fprintf(stderr, "RX: dropping %u blocks (%u samples)\n",
            drop_blocks, drop_blocks * block_size / SAMPLE_SIZE);
    for (uint32_t i = 0; i < drop_blocks; i++) {
        if (rx_get_block(s->drv, &r) < 0)
            goto done;
    }

    while (1) {
        if (rx_get_block(s->drv, &r) < 0)
            goto done;
        if (tcp_send(client, s->map + r.rd, block_size) < 0)
            goto done;
        g_rx_stats.bytes += block_size;
    }

done:
    if (s->ctx->cli->tx_mode != MODE_NONE) {
        pthread_mutex_lock(&s->ctx->start_mutex);
        s->ctx->rx_session_active = false;
        pthread_mutex_unlock(&s->ctx->start_mutex);
    }
    return -1;
}

static int rx_send_udp(struct driver *drv, const uint8_t *map, const char *host, int port) {
    int ret = 1;
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        perror("socket");
        return 1;
    }

    struct sockaddr_in dest = {
        .sin_family = AF_INET,
        .sin_port = htons(port),
    };
    if (inet_pton(AF_INET, host, &dest.sin_addr) != 1) {
        fprintf(stderr, "inet_pton failed\n");
        goto out;
    }

    int sndbuf = SOCK_BUF_BYTES;
    setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));

    struct rx_read r;
    while (1) {
        if (rx_get_block(drv, &r) < 0)
            goto out;
        if (udp_send_ring(sock, &dest, map + r.rd, drv->block_size) < 0)
            goto out;
        g_rx_stats.bytes += drv->block_size;
    }

out:
    close(sock);
    return ret;
}

static int rx_task(struct app_ctx *ctx) {
    const struct cli_cfg *cli = ctx->cli;

    uint8_t *map = driver_rx_mmap(&ctx->drv);
    if (!map) {
        driver_close(&ctx->drv);
        return 1;
    }
    g_rx_stats.buf_size = ctx->drv.rx_buf_size;

    if (cli->rx_mode == MODE_TCP) {
        int client = tcp_accept(ctx->rx_server_fd, SOCK_BUF_BYTES, 0, 1, "RX");
        if (client >= 0) {
            struct rx_session s = {.drv = &ctx->drv, .map = map, .ctx = ctx};
            rx_tcp_session(client, &s);
            close(client);
            fprintf(stderr, "RX client disconnected\n");
        }
    } else {
        rx_send_udp(&ctx->drv, map, cli->rx_host, cli->rx_port);
    }

    driver_rx_munmap(&ctx->drv, map);
    // Close the driver to signal the TX thread (if combined) that this session is done.
    driver_close(&ctx->drv);
    return 0;
}

void *rx_thread(void *arg) { return (void *)(intptr_t)rx_task(arg); }
