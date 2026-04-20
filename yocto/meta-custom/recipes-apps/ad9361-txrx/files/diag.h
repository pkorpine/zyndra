#ifndef AD9361_DIAG_H
#define AD9361_DIAG_H

#include "cli.h"

int diag_test(struct app_ctx *ctx);
int diag_membench(struct app_ctx *ctx, int loops);
int diag_loopback(struct app_ctx *ctx);
int diag_prbs(struct app_ctx *ctx);

#endif
