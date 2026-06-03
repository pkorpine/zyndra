#define _GNU_SOURCE
#include <getopt.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "cli.h"
#include "diag.h"
#include "net.h"
#include "rx.h"
#include "stats.h"
#include "tx.h"

// Pin a specific pthread to a CPU. Errors are silently ignored.
static void pin_thread(pthread_t thr, int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    pthread_setaffinity_np(thr, sizeof(set), &set);
}

static void usage(const char *prog) {
    fprintf(stderr,
            "Usage: %s [OPTIONS]\n"
            "\n"
            "Streaming (RX = from antenna to net; TX = from net to antenna).\n"
            "RX and TX may be combined to run simultaneously.\n"
            "  --rx-tcp PORT          serve RX samples to a TCP client on PORT\n"
            "  --rx-udp HOST:PORT     push RX samples as UDP datagrams to HOST:PORT\n"
            "  --tx-tcp PORT          accept TX samples from a TCP client on PORT\n"
            "  --tx-udp PORT          accept TX samples as UDP datagrams on PORT\n"
            "  --tx-depth MSAMPLES    limit TX ring depth (requires --tx-tcp or --tx-udp)\n"
            "\n"
            "Diagnostics (mutually exclusive with each other and with streaming):\n"
            "  --test                 print RX ring pointers\n"
            "  --loopback             TX tone, print RX samples\n"
            "  --prbs                 TX PRBS, verify RX\n"
            "  --membench LOOPS       benchmark memcpy from RX ring\n"
            "\n"
            "  --help                 show this help\n",
            prog);
}

int main(int argc, char **argv) {
    enum {
        OPT_RX_TCP = 256,
        OPT_RX_UDP,
        OPT_TX_TCP,
        OPT_TX_UDP,
        OPT_TX_DEPTH,
        OPT_TEST,
        OPT_LOOPBACK,
        OPT_PRBS,
        OPT_MEMBENCH,
        OPT_HELP,
    };
    static const struct option opts[] = {
        {"rx-tcp", required_argument, 0, OPT_RX_TCP},
        {"rx-udp", required_argument, 0, OPT_RX_UDP},
        {"tx-tcp", required_argument, 0, OPT_TX_TCP},
        {"tx-udp", required_argument, 0, OPT_TX_UDP},
        {"tx-depth", required_argument, 0, OPT_TX_DEPTH},
        {"test", no_argument, 0, OPT_TEST},
        {"loopback", no_argument, 0, OPT_LOOPBACK},
        {"prbs", no_argument, 0, OPT_PRBS},
        {"membench", required_argument, 0, OPT_MEMBENCH},
        {"help", no_argument, 0, OPT_HELP},
        {0, 0, 0, 0},
    };

    struct cli_cfg cfg = {0};

    int c;
    while ((c = getopt_long(argc, argv, "", opts, NULL)) != -1) {
        switch (c) {
        case OPT_RX_TCP:
            if (cfg.rx_mode) {
                fprintf(stderr, "only one --rx-* allowed\n");
                return 1;
            }
            cfg.rx_mode = MODE_TCP;
            cfg.rx_port = atoi(optarg);
            break;
        case OPT_RX_UDP: {
            if (cfg.rx_mode) {
                fprintf(stderr, "only one --rx-* allowed\n");
                return 1;
            }
            char *colon = strrchr(optarg, ':');
            if (!colon) {
                fprintf(stderr, "--rx-udp expects HOST:PORT\n");
                return 1;
            }
            *colon = '\0';
            strncpy(cfg.rx_host, optarg, sizeof(cfg.rx_host) - 1);
            cfg.rx_port = atoi(colon + 1);
            cfg.rx_mode = MODE_UDP;
            break;
        }
        case OPT_TX_TCP:
            if (cfg.tx_mode) {
                fprintf(stderr, "only one --tx-* allowed\n");
                return 1;
            }
            cfg.tx_mode = MODE_TCP;
            cfg.tx_port = atoi(optarg);
            break;
        case OPT_TX_UDP:
            if (cfg.tx_mode) {
                fprintf(stderr, "only one --tx-* allowed\n");
                return 1;
            }
            cfg.tx_mode = MODE_UDP;
            cfg.tx_port = atoi(optarg);
            break;
        case OPT_TX_DEPTH:
            cfg.tx_depth_msamples = atof(optarg);
            break;
        case OPT_TEST:
            cfg.diagnostic = DIAG_TEST;
            break;
        case OPT_LOOPBACK:
            cfg.diagnostic = DIAG_LOOPBACK;
            break;
        case OPT_PRBS:
            cfg.diagnostic = DIAG_PRBS;
            break;
        case OPT_MEMBENCH:
            cfg.diagnostic = DIAG_MEMBENCH;
            cfg.membench_loops = atoi(optarg);
            break;
        case OPT_HELP:
            usage(argv[0]);
            return 0;
        case '?':
            usage(argv[0]);
            return 1;
        default:
            return 1;
        }
    }
    if (optind != argc) {
        fprintf(stderr, "unexpected positional argument: %s\n", argv[optind]);
        usage(argv[0]);
        return 1;
    }

    int streaming = (cfg.rx_mode != MODE_NONE) || (cfg.tx_mode != MODE_NONE);
    if (cfg.diagnostic != DIAG_NONE && streaming) {
        fprintf(stderr, "diagnostic modes cannot combine with --rx-* / --tx-*\n");
        return 1;
    }
    if (cfg.tx_depth_msamples > 0 && cfg.tx_mode == MODE_NONE) {
        fprintf(stderr, "--tx-depth requires --tx-tcp or --tx-udp\n");
        return 1;
    }
    if (cfg.diagnostic == DIAG_NONE && !streaming) {
        usage(argv[0]);
        return 1;
    }

    struct app_ctx ctx = {0};
    ctx.cli = &cfg;
    ctx.drv.fd = -1;
    ctx.rx_server_fd = -1;
    ctx.tx_server_fd = -1;
    pthread_mutex_init(&ctx.start_mutex, NULL);
    pthread_cond_init(&ctx.start_cond, NULL);

    // Diagnostics: open driver once, run, close, exit.
    if (cfg.diagnostic != DIAG_NONE) {
        if (driver_open(&ctx.drv) < 0)
            return 1;
        int ret = 0;
        switch (cfg.diagnostic) {
        case DIAG_TEST:
            ret = diag_test(&ctx);
            break;
        case DIAG_LOOPBACK:
            ret = diag_loopback(&ctx);
            break;
        case DIAG_PRBS:
            ret = diag_prbs(&ctx);
            break;
        case DIAG_MEMBENCH:
            ret = diag_membench(&ctx, cfg.membench_loops);
            break;
        default:
            break;
        }
        driver_close(&ctx.drv);
        return ret;
    }

    // Streaming: stats thread runs for the lifetime of the process.
    pthread_t stats_thr;
    pthread_create(&stats_thr, NULL, status_thread, NULL);
    pin_thread(stats_thr, 0);

    // TCP server sockets are created once and survive across reconnections.
    if (cfg.rx_mode == MODE_TCP) {
        ctx.rx_server_fd = tcp_listen(cfg.rx_port, "RX");
        if (ctx.rx_server_fd < 0)
            return 1;
    }
    if (cfg.tx_mode == MODE_TCP) {
        ctx.tx_server_fd = tcp_listen(cfg.tx_port, "TX");
        if (ctx.tx_server_fd < 0)
            return 1;
    }

    // Reconnect loop: open the driver fresh for each session so the FPGA is
    // properly reset between connections.
    for (;;) {
        ctx.rx_session_active = false;

        if (driver_open(&ctx.drv) < 0)
            break;

        if (cfg.rx_mode != MODE_NONE && cfg.tx_mode != MODE_NONE) {
            pthread_t rt, tt;
            pthread_create(&rt, NULL, rx_thread, &ctx);
            pthread_create(&tt, NULL, tx_thread, &ctx);
            pin_thread(rt, 1);
            pin_thread(tt, 0);
            pthread_join(rt, NULL);
            pthread_join(tt, NULL);
        } else if (cfg.rx_mode != MODE_NONE) {
            pin_thread(pthread_self(), 1);
            rx_thread(&ctx);
        } else if (cfg.tx_mode != MODE_NONE) {
            pin_thread(pthread_self(), 1);
            tx_thread(&ctx);
        }

        // No-op if a task already closed the driver (combined mode cross-signal).
        driver_close(&ctx.drv);
    }

    if (ctx.rx_server_fd >= 0)
        close(ctx.rx_server_fd);
    if (ctx.tx_server_fd >= 0)
        close(ctx.tx_server_fd);
    return 0;
}
