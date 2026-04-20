#include "driver.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define AD936X_AXI_IOC_MAGIC 'a'
#define AD936X_AXI_IOC_GET_RX_BUFSIZE _IOR(AD936X_AXI_IOC_MAGIC, 0, uint32_t)
#define AD936X_AXI_IOC_GET_BLOCKSIZE _IOR(AD936X_AXI_IOC_MAGIC, 1, uint32_t)
#define AD936X_AXI_IOC_GET_TX_BUFSIZE _IOR(AD936X_AXI_IOC_MAGIC, 2, uint32_t)

// Open device O_RDWR and populate ring sizes via ioctls.
int driver_open(struct driver *drv) {
    drv->fd = open("/dev/ad936x-axi", O_RDWR);
    if (drv->fd < 0) {
        perror("open /dev/ad936x-axi");
        return -1;
    }
    if (ioctl(drv->fd, AD936X_AXI_IOC_GET_RX_BUFSIZE, &drv->rx_buf_size) < 0 ||
        ioctl(drv->fd, AD936X_AXI_IOC_GET_TX_BUFSIZE, &drv->tx_buf_size) < 0 ||
        ioctl(drv->fd, AD936X_AXI_IOC_GET_BLOCKSIZE, &drv->block_size) < 0) {
        perror("ioctl");
        close(drv->fd);
        drv->fd = -1;
        return -1;
    }
    fprintf(stderr, "Driver: RX=%u KB, TX=%u KB, block=%u\n", drv->rx_buf_size / 1024,
            drv->tx_buf_size / 1024, drv->block_size);
    return 0;
}

void driver_close(struct driver *drv) {
    if (drv->fd >= 0)
        close(drv->fd);
    drv->fd = -1;
}

int driver_rx_get_block(struct driver *drv, struct rx_read *r) {
    if (read(drv->fd, r, sizeof(*r)) != sizeof(*r)) {
        perror("rx read");
        return -1;
    }
    return 0;
}

int driver_tx_put_block(struct driver *drv, uint32_t wr) {
    struct tx_write tw = {.wr = wr};
    if (write(drv->fd, &tw, sizeof(tw)) != sizeof(tw)) {
        perror("tx write");
        return -1;
    }
    return 0;
}

uint8_t *driver_rx_mmap(struct driver *drv) {
    uint8_t *map = mmap(NULL, drv->rx_buf_size, PROT_READ, MAP_SHARED, drv->fd, 0);
    if (map == MAP_FAILED) {
        perror("mmap rx");
        return NULL;
    }
    return map;
}

void driver_rx_munmap(struct driver *drv, uint8_t *map) { munmap(map, drv->rx_buf_size); }

int16_t *driver_tx_mmap(struct driver *drv, uint32_t size) {
    long page_size = sysconf(_SC_PAGE_SIZE);
    int16_t *map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, drv->fd, page_size);
    if (map == MAP_FAILED) {
        perror("mmap tx");
        return NULL;
    }
    return map;
}

void driver_tx_munmap(int16_t *map, uint32_t size) { munmap(map, size); }
