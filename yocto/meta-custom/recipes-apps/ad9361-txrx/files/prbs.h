#ifndef AD9361_PRBS_H
#define AD9361_PRBS_H

#include <stdint.h>

// PRBS16 sequence length: 2^16 - 1
#define PRBS_LEN 65535

struct prbs_iq {
    int16_t i, q;
};

extern struct prbs_iq g_prbs_lut[PRBS_LEN]; // position -> IQ sample
extern uint16_t g_prbs_pos[65536];          // LFSR state -> position

uint16_t prbs_state_from_iq(uint16_t i, uint16_t q);
void prbs_init(void);
void prbs_fill_block(int16_t *dst, uint32_t num_samples, uint32_t *prbs_pos_p);

#endif
