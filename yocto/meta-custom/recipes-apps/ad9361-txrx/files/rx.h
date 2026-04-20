#ifndef AD9361_RX_H
#define AD9361_RX_H

#include "cli.h"

// arg = struct app_ctx *. Returns (void *)(intptr_t)result.
void *rx_thread(void *arg);

#endif
