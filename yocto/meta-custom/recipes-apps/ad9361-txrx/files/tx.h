#ifndef AD9361_TX_H
#define AD9361_TX_H

#include "cli.h"

// arg = struct app_ctx *. Returns (void *)(intptr_t)result.
void *tx_thread(void *arg);

#endif
