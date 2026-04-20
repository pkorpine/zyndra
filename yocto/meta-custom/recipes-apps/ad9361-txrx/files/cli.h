#ifndef AD9361_CLI_H
#define AD9361_CLI_H

#include "driver.h"

enum mode { MODE_NONE, MODE_TCP, MODE_UDP };
enum diagnostic { DIAG_NONE, DIAG_TEST, DIAG_LOOPBACK, DIAG_PRBS, DIAG_MEMBENCH };

struct cli_cfg {
    enum diagnostic diagnostic;
    int membench_loops;

    enum mode rx_mode, tx_mode;
    int rx_port;      // tcp listen, or udp dest
    char rx_host[64]; // udp dest host
    int tx_port;      // tcp listen, or udp listen
    double tx_depth_msamples;
};

struct app_ctx {
    struct driver drv;
    const struct cli_cfg *cli;
};

#endif
