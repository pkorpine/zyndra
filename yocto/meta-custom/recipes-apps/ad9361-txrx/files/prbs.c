#include "prbs.h"

#include <stdio.h>
#include <string.h>

#include "driver.h" // SAMPLE_SIZE

struct prbs_iq g_prbs_lut[PRBS_LEN];
uint16_t g_prbs_pos[65536];

static uint16_t bitrev12(uint16_t x) {
    uint16_t out = 0;
    for (int i = 0; i < 12; i++)
        out |= ((x >> i) & 1) << (11 - i);
    return out;
}

static uint16_t lfsr_next(uint16_t state) {
    // Polynomial: next = {state[14:0], (^state[15:4]) ^ (^state[2:1])}
    uint32_t xor_hi = __builtin_popcount((state >> 4) & 0xFFF) & 1;
    uint32_t xor_lo = __builtin_popcount((state >> 1) & 0x3) & 1;
    uint16_t new_bit = xor_hi ^ xor_lo;
    return ((state << 1) | new_bit) & 0xFFFF;
}

// Recover LFSR state from a received I/Q pair.
uint16_t prbs_state_from_iq(uint16_t i, uint16_t q) {
    uint16_t q_rev = bitrev12(q & 0xFFF);
    return ((i & 0xFFF) << 4) | (q_rev & 0xF);
}

// Build LUTs mapping position->IQ and LFSR state->position.
void prbs_init(void) {
    uint16_t state = 1;
    for (int n = 0; n < PRBS_LEN; n++) {
        uint16_t i_val = (state >> 4) & 0xFFF;
        uint16_t q_rev = bitrev12(state & 0xFFF);
        g_prbs_lut[n].i = (int16_t)(i_val << 4);
        g_prbs_lut[n].q = (int16_t)(q_rev << 4);
        g_prbs_pos[state] = n;
        state = lfsr_next(state);
    }
    fprintf(stderr, "PRBS LUT built: %d samples\n", PRBS_LEN);
}

// Copy num_samples from the PRBS LUT to dst, advancing *prbs_pos_p with wrap.
void prbs_fill_block(int16_t *dst, uint32_t num_samples, uint32_t *prbs_pos_p) {
    uint32_t p = *prbs_pos_p;
    uint32_t remaining = num_samples;

    while (remaining > 0) {
        uint32_t chunk = PRBS_LEN - p;
        if (chunk > remaining)
            chunk = remaining;
        memcpy(dst, &g_prbs_lut[p], chunk * SAMPLE_SIZE);
        dst += chunk * 2;
        remaining -= chunk;
        p = (p + chunk) % PRBS_LEN;
    }
    *prbs_pos_p = p;
}
