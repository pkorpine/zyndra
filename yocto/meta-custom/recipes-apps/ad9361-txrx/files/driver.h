#ifndef AD9361_DRIVER_H
#define AD9361_DRIVER_H

#include <stdint.h>

#define SAMPLE_SIZE 4
#define TXRX_PREFILL_SAMPLES (16384 * 128)

struct rx_read {
    uint32_t rd;
    uint32_t hw_wr;
    uint32_t lost_bytes;
};

struct tx_write {
    uint32_t wr;
};

struct driver {
    int fd;
    uint32_t rx_buf_size;
    uint32_t tx_buf_size;
    uint32_t block_size;
};

static inline uint32_t ringbuf_used(uint32_t rd, uint32_t hw_wr, uint32_t size) {
    return (hw_wr >= rd) ? (hw_wr - rd) : (size - rd + hw_wr);
}

int driver_open(struct driver *drv);
void driver_close(struct driver *drv);
int driver_enable(struct driver *drv);

int driver_rx_get_block(struct driver *drv, struct rx_read *r);
int driver_tx_put_block(struct driver *drv, uint32_t wr);

uint8_t *driver_rx_mmap(struct driver *drv);
void driver_rx_munmap(struct driver *drv, uint8_t *map);
int16_t *driver_tx_mmap(struct driver *drv, uint32_t size);
void driver_tx_munmap(int16_t *map, uint32_t size);

#endif
