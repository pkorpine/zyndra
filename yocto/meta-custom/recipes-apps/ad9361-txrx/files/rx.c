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
    while (1) {
        if (rx_get_block(s->drv, &r) < 0)
            return -1;
        if (tcp_send(client, s->map + r.rd, s->drv->block_size) < 0)
            return -1;
        g_rx_stats.bytes += s->drv->block_size;
    }
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
    if (!map)
        return 1;

    g_rx_stats.buf_size = ctx->drv.rx_buf_size;

    int ret;
    if (cli->rx_mode == MODE_TCP) {
        struct rx_session s = {.drv = &ctx->drv, .map = map};
        ret = tcp_serve(cli->rx_port, SOCK_BUF_BYTES, 0, 1, "RX", rx_tcp_session, &s);
    } else {
        ret = rx_send_udp(&ctx->drv, map, cli->rx_host, cli->rx_port);
    }

    driver_rx_munmap(&ctx->drv, map);
    return ret;
}

void *rx_thread(void *arg) { return (void *)(intptr_t)rx_task(arg); }
