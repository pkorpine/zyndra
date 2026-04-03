#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define AD936X_AXI_IOC_MAGIC 'a'
#define AD936X_AXI_IOC_GET_RX_BUFSIZE _IOR(AD936X_AXI_IOC_MAGIC, 0, uint32_t)
#define AD936X_AXI_IOC_GET_BLOCKSIZE _IOR(AD936X_AXI_IOC_MAGIC, 1, uint32_t)
#define AD936X_AXI_IOC_GET_TX_BUFSIZE _IOR(AD936X_AXI_IOC_MAGIC, 2, uint32_t)

struct rxbuf {
    int fd;
    uint8_t *map;
    uint32_t buf_size;
    uint32_t block_size;
};

struct rx_read {
    uint32_t rd;
    uint32_t hw_wr;
    uint32_t lost_bytes;
};

struct tx_write {
    uint32_t wr;
};

#define DATAGRAM_SIZE 1472

#define SAMPLE_SIZE 4

/* PRBS16 sequence length: 2^16 - 1 */
#define PRBS_LEN 65535

struct prbs_iq {
    int16_t i, q;
};

static struct prbs_iq prbs_lut[PRBS_LEN];  /* position -> IQ sample (~256 KB) */
static uint16_t prbs_pos[65536];           /* LFSR state -> position (~128 KB) */

static struct {
    volatile uint64_t send_bytes;
    volatile uint64_t overrun_bytes;
    volatile uint32_t buf_used;
    uint32_t buf_size;
} stats;

static uint16_t bitrev12(uint16_t x)
{
    uint16_t out = 0;
    for (int i = 0; i < 12; i++)
        out |= ((x >> i) & 1) << (11 - i);
    return out;
}

static uint16_t lfsr_next(uint16_t state)
{
    /* Polynomial: next = {state[14:0], (^state[15:4]) ^ (^state[2:1])} */
    uint32_t xor_hi = __builtin_popcount((state >> 4) & 0xFFF) & 1;
    uint32_t xor_lo = __builtin_popcount((state >> 1) & 0x3) & 1;
    uint16_t new_bit = xor_hi ^ xor_lo;
    return ((state << 1) | new_bit) & 0xFFFF;
}

static uint16_t state_from_iq(uint16_t i, uint16_t q)
{
    uint16_t q_rev = bitrev12(q & 0xFFF);
    return ((i & 0xFFF) << 4) | (q_rev & 0xF);
}

static void prbs_init(void)
{
    uint16_t state = 1;
    for (int n = 0; n < PRBS_LEN; n++) {
        uint16_t i_val = (state >> 4) & 0xFFF;
        uint16_t q_rev = bitrev12(state & 0xFFF);
        prbs_lut[n].i = (int16_t)(i_val << 4);
        prbs_lut[n].q = (int16_t)(q_rev << 4);
        prbs_pos[state] = n;
        state = lfsr_next(state);
    }
    fprintf(stderr, "PRBS LUT built: %d samples\n", PRBS_LEN);
}

static int rxbuf_open(struct rxbuf *rx) {
    int fd = open("/dev/ad936x-axi", O_RDONLY);
    if (fd < 0) {
        perror("open /dev/ad936x-axi");
        return -1;
    }

    uint32_t buf_size, block_size;
    if (ioctl(fd, AD936X_AXI_IOC_GET_RX_BUFSIZE, &buf_size) < 0) {
        perror("ioctl GET_BUFSIZE");
        close(fd);
        return -1;
    }
    if (ioctl(fd, AD936X_AXI_IOC_GET_BLOCKSIZE, &block_size) < 0) {
        perror("ioctl GET_BLOCKSIZE");
        close(fd);
        return -1;
    }

    uint8_t *map = mmap(NULL, buf_size, PROT_READ, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return -1;
    }

    *rx = (struct rxbuf){.fd = fd, .map = map, .buf_size = buf_size, .block_size = block_size};
    stats.buf_size = buf_size;
    fprintf(stderr, "Ring buffer: %u MB, block size: %u\n", buf_size / (1024 * 1024), block_size);
    return 0;
}

static void rxbuf_close(struct rxbuf *rx) {
    munmap(rx->map, rx->buf_size);
    close(rx->fd);
}

static int rxbuf_read(const struct rxbuf *rx, struct rx_read *r) {
    if (read(rx->fd, r, sizeof(*r)) != sizeof(*r)) {
        perror("read");
        return -1;
    }

    uint32_t used = (r->hw_wr >= r->rd) ? (r->hw_wr - r->rd) : (rx->buf_size - r->rd + r->hw_wr);
    stats.buf_used = used;
    stats.overrun_bytes += r->lost_bytes;

    return 0;
}

static int tcp_send(int fd, const void *buf, size_t len) {
    const char *p = buf;
    while (len > 0) {
        ssize_t n = send(fd, p, len, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            perror("send");
            return -1;
        }
        if (n == 0)
            return -1;
        p += n;
        len -= n;
    }
    return 0;
}

static int udp_send_ring(int sock, struct sockaddr_in *dest, const uint8_t *data, uint32_t len) {
    static uint8_t wrap_buf[DATAGRAM_SIZE];
    static uint32_t wrap_pos = 0;

    struct mmsghdr msgs[64];
    struct iovec iovs[64];
    int count = 0;

    if (wrap_pos > 0) {
        uint32_t need = DATAGRAM_SIZE - wrap_pos;
        memcpy(wrap_buf + wrap_pos, data, need);
        data += need;
        len -= need;

        iovs[0].iov_base = wrap_buf;
        iovs[0].iov_len = DATAGRAM_SIZE;
        msgs[0].msg_hdr = (struct msghdr){
            .msg_iov = &iovs[0],
            .msg_iovlen = 1,
            .msg_name = dest,
            .msg_namelen = sizeof(*dest),
        };
        count++;
        wrap_pos = 0;
    }

    while (len >= DATAGRAM_SIZE && count < 64) {
        iovs[count].iov_base = (void *)data;
        iovs[count].iov_len = DATAGRAM_SIZE;
        msgs[count].msg_hdr = (struct msghdr){
            .msg_iov = &iovs[count],
            .msg_iovlen = 1,
            .msg_name = dest,
            .msg_namelen = sizeof(*dest),
        };
        data += DATAGRAM_SIZE;
        len -= DATAGRAM_SIZE;
        count++;
    }

    if (count > 0) {
        if (sendmmsg(sock, msgs, count, 0) < 0)
            return -1;
    }

    if (len > 0) {
        memcpy(wrap_buf, data, len);
        wrap_pos = len;
    }

    return 0;
}

static void *status_thread(void *) {
    uint64_t prev_bytes = 0;
    uint64_t prev_overrun = 0;
    struct timespec last;
    clock_gettime(CLOCK_MONOTONIC, &last);

    while (1) {
        usleep(1000000);
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double elapsed = (now.tv_sec - last.tv_sec) + (now.tv_nsec - last.tv_nsec) * 1e-9;

        uint64_t bytes = stats.send_bytes;
        uint64_t overrun = stats.overrun_bytes;
        uint32_t buf_used = stats.buf_used;
        double mbps = (double)(bytes - prev_bytes) / elapsed / (1024.0 * 1024.0);
        double msps = (double)(bytes - prev_bytes) / SAMPLE_SIZE / elapsed / 1e6;
        uint32_t buf_pct = stats.buf_size ? buf_used / (stats.buf_size / 100) : 0;
        fprintf(stderr, "%.1f MB/s %.2f MSPS buf=%u%% lost=%llu\n", mbps, msps, buf_pct,
                (unsigned long long)(overrun - prev_overrun));

        prev_bytes = bytes;
        prev_overrun = overrun;
        last = now;
    }
    return NULL;
}

static int send_using_tcp(struct rxbuf *rx, int port) {
    int server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0) {
        perror("socket");
        return 1;
    }

    int one = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_addr.s_addr = INADDR_ANY,
        .sin_port = htons(port),
    };
    if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(server);
        return 1;
    }
    listen(server, 1);

    while (1) {
        fprintf(stderr, "Waiting for connection on port %d...\n", port);
        int client = accept(server, NULL, NULL);
        if (client < 0) {
            perror("accept");
            continue;
        }
        fprintf(stderr, "Client connected\n");

        int sndbuf = 8 * 1024 * 1024;
        setsockopt(client, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

        struct rx_read r;
        while (1) {
            if (rxbuf_read(rx, &r) < 0)
                break;
            if (tcp_send(client, rx->map + r.rd, rx->block_size) < 0)
                break;
            stats.send_bytes += rx->block_size;
        }
        fprintf(stderr, "Client disconnected\n");
        close(client);
    }

    close(server);
    return 0;
}

static int send_using_udp(struct rxbuf *rx, const char *host, int port) {
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
        close(sock);
        return 1;
    }

    int sndbuf = 8 * 1024 * 1024;
    setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));

    struct rx_read r;
    while (1) {
        if (rxbuf_read(rx, &r) < 0)
            return 1;
        if (udp_send_ring(sock, &dest, rx->map + r.rd, rx->block_size) < 0)
            return 1;
        stats.send_bytes += rx->block_size;
    }

    close(sock);
    return 0;
}

int test() {
    struct rxbuf rx;
    if (rxbuf_open(&rx) < 0)
        return 1;

    struct rx_read r;
    while (1) {
        usleep(100000);

        if (rxbuf_read(&rx, &r) < 0) {
            rxbuf_close(&rx);
            return 1;
        }

        uint32_t used = (r.hw_wr >= r.rd) ? (r.hw_wr - r.rd) : (rx.buf_size - r.rd + r.hw_wr);

        printf("rd=0x%08x hw_wr=0x%08x used=%u (%u%%)\n", r.rd, r.hw_wr, used,
               used / (rx.buf_size / 100));

        uint32_t *map = (uint32_t *)rx.map;
        if (r.hw_wr != r.rd)
            printf("first word: 0x%08x\n", map[r.rd / 4]);
        else
            printf("no new data\n");
    }

    rxbuf_close(&rx);
}

int membench(int loops) {
    struct rxbuf rx;
    if (rxbuf_open(&rx) < 0)
        return 1;

    const size_t block_size = 64 * 1024;
    uint8_t *dst = malloc(block_size);
    if (!dst) {
        perror("malloc");
        rxbuf_close(&rx);
        return 1;
    }

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    uint64_t total_bytes = 0;
    for (int i = 0; i < loops; i++) {
        for (size_t off = 0; off < rx.buf_size; off += block_size) {
            memcpy(dst, rx.map + off, block_size);
            __asm__ volatile("" ::: "memory");
        }
        total_bytes += rx.buf_size;
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);

    double elapsed = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) * 1e-9;
    double mb = (double)total_bytes / (1024.0 * 1024.0);
    printf("Copied %.0f MB in %.3f s => %.1f MB/s\n", mb, elapsed, mb / elapsed);

    free(dst);
    rxbuf_close(&rx);
    return 0;
}

struct loopback_ctx {
    int fd;
    int16_t *tx_map;
    uint32_t tx_buf_size;
    uint32_t block_size;
    int prbs;       /* if set, fill blocks from PRBS LUT instead of pre-filled tone */
};

#define TONE_PERIOD 64

static void generate_tone(int16_t *buf, uint32_t num_samples) {
    /* Generate one period */
    for (int i = 0; i < TONE_PERIOD; i++) {
        double phase = 2.0 * M_PI * i / TONE_PERIOD;
        buf[i * 2 + 0] = (int16_t)(0x7FF0 * cos(phase)); /* I */
        buf[i * 2 + 1] = (int16_t)(0x7FF0 * sin(phase)); /* Q */
    }
    /* Tile across entire buffer */
    uint32_t period_bytes = TONE_PERIOD * SAMPLE_SIZE;
    uint32_t total_bytes = num_samples * SAMPLE_SIZE;
    for (uint32_t off = period_bytes; off < total_bytes; off += period_bytes) {
        uint32_t chunk = total_bytes - off;
        if (chunk > period_bytes)
            chunk = period_bytes;
        memcpy((uint8_t *)buf + off, buf, chunk);
    }
}

/* Fill dst with num_samples from prbs_lut starting at *prbs_pos_p,
 * handling LUT wraparound. Updates *prbs_pos_p. */
static void prbs_fill_block(int16_t *dst, uint32_t num_samples, uint32_t *prbs_pos_p)
{
    uint32_t p = *prbs_pos_p;
    uint32_t remaining = num_samples;

    while (remaining > 0) {
        uint32_t chunk = PRBS_LEN - p;
        if (chunk > remaining)
            chunk = remaining;
        memcpy(dst, &prbs_lut[p], chunk * SAMPLE_SIZE);
        dst += chunk * 2;  /* 2 int16_t per sample */
        remaining -= chunk;
        p = (p + chunk) % PRBS_LEN;
    }
    *prbs_pos_p = p;
}

static void *tx_thread(void *arg) {
    struct loopback_ctx *ctx = arg;
    uint32_t wr = 0;
    uint32_t prbs_p = 0;

    /* Feed blocks to FPGA; write() blocks when buffer is full */
    while (1) {
        if (ctx->prbs) {
            int16_t *dst = (int16_t *)((uint8_t *)ctx->tx_map + wr);
            prbs_fill_block(dst, ctx->block_size / SAMPLE_SIZE, &prbs_p);
        }
        wr = (wr + ctx->block_size) % ctx->tx_buf_size;
        struct tx_write tw = {.wr = wr};
        if (write(ctx->fd, &tw, sizeof(tw)) != sizeof(tw)) {
            perror("tx write");
            break;
        }
    }
    return NULL;
}

static int loopback_test(void) {
    int fd = open("/dev/ad936x-axi", O_RDWR);
    if (fd < 0) {
        perror("open /dev/ad936x-axi");
        return 1;
    }

    uint32_t rx_buf_size, tx_buf_size, block_size;
    if (ioctl(fd, AD936X_AXI_IOC_GET_RX_BUFSIZE, &rx_buf_size) < 0 ||
        ioctl(fd, AD936X_AXI_IOC_GET_BLOCKSIZE, &block_size) < 0 ||
        ioctl(fd, AD936X_AXI_IOC_GET_TX_BUFSIZE, &tx_buf_size) < 0) {
        perror("ioctl");
        close(fd);
        return 1;
    }

    fprintf(stderr, "RX buf: %u KB, TX buf: %u KB, block: %u\n", rx_buf_size / 1024,
            tx_buf_size / 1024, block_size);

    /* mmap RX buffer (pgoff=0, read-only) */
    uint8_t *rx_map = mmap(NULL, rx_buf_size, PROT_READ, MAP_SHARED, fd, 0);
    if (rx_map == MAP_FAILED) {
        perror("mmap rx");
        close(fd);
        return 1;
    }

    /* mmap TX buffer (pgoff=1, read-write) */
    long page_size = sysconf(_SC_PAGE_SIZE);
    int16_t *tx_map = mmap(NULL, tx_buf_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, page_size);
    if (tx_map == MAP_FAILED) {
        perror("mmap tx");
        munmap(rx_map, rx_buf_size);
        close(fd);
        return 1;
    }

    /* Fill TX buffer with tone, then start TX thread */
    generate_tone(tx_map, tx_buf_size / SAMPLE_SIZE);

    struct loopback_ctx tx_ctx = {
        .fd = fd, .tx_map = tx_map, .tx_buf_size = tx_buf_size,
        .block_size = block_size, .prbs = 0};
    pthread_t tx_thr;
    pthread_create(&tx_thr, NULL, tx_thread, &tx_ctx);

    fprintf(stderr, "Loopback running (tone period=%d samples)...\n", TONE_PERIOD);

    /* RX loop in main thread */
    struct rx_read r;
    uint32_t count = 0;
    while (1) {
        if (read(fd, &r, sizeof(r)) != sizeof(r)) {
            perror("read");
            break;
        }

        int16_t *samples = (int16_t *)(rx_map + r.rd);
        if (count % 16 == 0) { /* print every 16th block */
            printf("blk %u rd=0x%08x wr=0x%08x lost=%u | ", count, r.rd, r.hw_wr, r.lost_bytes);
            for (int i = 0; i < 8; i++)
                printf("(%6d,%6d) ", samples[i * 2], samples[i * 2 + 1]);
            printf("\n");
        }
        count++;
    }

    munmap(tx_map, tx_buf_size);
    munmap(rx_map, rx_buf_size);
    close(fd);
    return 0;
}

static int tcp_recv_full(int fd, void *buf, size_t len) {
    char *p = buf;
    while (len > 0) {
        ssize_t n = recv(fd, p, len, 0);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            perror("recv");
            return -1;
        }
        if (n == 0)
            return -1; /* client disconnected */
        p += n;
        len -= n;
    }
    return 0;
}

static int receive_to_tx(int port, double depth_msamples) {
    int fd = open("/dev/ad936x-axi", O_RDWR);
    if (fd < 0) {
        perror("open /dev/ad936x-axi");
        return 1;
    }

    uint32_t tx_buf_size, block_size;
    if (ioctl(fd, AD936X_AXI_IOC_GET_TX_BUFSIZE, &tx_buf_size) < 0 ||
        ioctl(fd, AD936X_AXI_IOC_GET_BLOCKSIZE, &block_size) < 0) {
        perror("ioctl");
        close(fd);
        return 1;
    }

    uint32_t tx_effective = tx_buf_size;
    if (depth_msamples > 0) {
        tx_effective = (uint32_t)(depth_msamples * 1000000.0) * SAMPLE_SIZE;
        tx_effective = ((tx_effective + block_size - 1) / block_size) * block_size;
        if (tx_effective > tx_buf_size)
            tx_effective = tx_buf_size;
    }

    fprintf(stderr, "TX buf: %u KB (max %u KB), block: %u\n",
            tx_effective / 1024, tx_buf_size / 1024, block_size);

    long page_size = sysconf(_SC_PAGE_SIZE);
    int16_t *tx_map = mmap(NULL, tx_effective, PROT_READ | PROT_WRITE,
                           MAP_SHARED, fd, page_size);
    if (tx_map == MAP_FAILED) {
        perror("mmap tx");
        close(fd);
        return 1;
    }

    int server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0) {
        perror("socket");
        munmap(tx_map, tx_buf_size);
        close(fd);
        return 1;
    }

    int one = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_addr.s_addr = INADDR_ANY,
        .sin_port = htons(port),
    };
    if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(server);
        munmap(tx_map, tx_effective);
        close(fd);
        return 1;
    }
    listen(server, 1);

    stats.buf_size = tx_effective;

    pthread_t stats_thr;
    pthread_create(&stats_thr, NULL, &status_thread, NULL);

    while (1) {
        fprintf(stderr, "Waiting for TX connection on port %d...\n", port);
        int client = accept(server, NULL, NULL);
        if (client < 0) {
            perror("accept");
            continue;
        }
        fprintf(stderr, "Client connected, streaming to TX\n");

        int rcvbuf = 8 * 1024 * 1024;
        setsockopt(client, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

        uint32_t wr = 0;
        while (1) {
            /* Receive directly into the mmap'd TX ringbuffer */
            if (tcp_recv_full(client, (uint8_t *)tx_map + wr, block_size) < 0)
                break;

            wr = (wr + block_size) % tx_effective;
            struct tx_write tw = {.wr = wr};
            if (write(fd, &tw, sizeof(tw)) != sizeof(tw)) {
                perror("tx write");
                break;
            }
            stats.send_bytes += block_size;
        }
        fprintf(stderr, "Client disconnected\n");
        close(client);
    }

    close(server);
    munmap(tx_map, tx_effective);
    close(fd);
    return 0;
}

static int prbs_test(void)
{
    prbs_init();

    int fd = open("/dev/ad936x-axi", O_RDWR);
    if (fd < 0) {
        perror("open /dev/ad936x-axi");
        return 1;
    }

    uint32_t rx_buf_size, tx_buf_size, block_size;
    if (ioctl(fd, AD936X_AXI_IOC_GET_RX_BUFSIZE, &rx_buf_size) < 0 ||
        ioctl(fd, AD936X_AXI_IOC_GET_BLOCKSIZE, &block_size) < 0 ||
        ioctl(fd, AD936X_AXI_IOC_GET_TX_BUFSIZE, &tx_buf_size) < 0) {
        perror("ioctl");
        close(fd);
        return 1;
    }

    fprintf(stderr, "RX buf: %u KB, TX buf: %u KB, block: %u\n",
            rx_buf_size / 1024, tx_buf_size / 1024, block_size);

    uint8_t *rx_map = mmap(NULL, rx_buf_size, PROT_READ, MAP_SHARED, fd, 0);
    if (rx_map == MAP_FAILED) {
        perror("mmap rx");
        close(fd);
        return 1;
    }

    long page_size = sysconf(_SC_PAGE_SIZE);
    int16_t *tx_map = mmap(NULL, tx_buf_size, PROT_READ | PROT_WRITE,
                           MAP_SHARED, fd, page_size);
    if (tx_map == MAP_FAILED) {
        perror("mmap tx");
        munmap(rx_map, rx_buf_size);
        close(fd);
        return 1;
    }

    /* Start TX thread — fills blocks with PRBS on the fly */
    struct loopback_ctx tx_ctx = {
        .fd = fd, .tx_map = tx_map, .tx_buf_size = tx_buf_size,
        .block_size = block_size, .prbs = 1,
    };
    pthread_t tx_thr;
    pthread_create(&tx_thr, NULL, tx_thread, &tx_ctx);

    fprintf(stderr, "PRBS test running...\n");

    /* RX PRBS verifier */
    struct rx_read r;
    int pos = -1;  /* -1 = not yet synced */
    uint64_t errors = 0, total_errors = 0, samples = 0;
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    while (1) {
        if (read(fd, &r, sizeof(r)) != sizeof(r)) {
            perror("read");
            break;
        }

        int16_t *blk = (int16_t *)(rx_map + r.rd);
        uint32_t num_samples = block_size / SAMPLE_SIZE;

        if (pos < 0) {
            /* Initial sync from first sample */
            uint16_t rx_i = (uint16_t)blk[0] >> 4;
            uint16_t rx_q = (uint16_t)blk[1] >> 4;
            uint16_t st = state_from_iq(rx_i, rx_q);
            if (st != 0)
                pos = prbs_pos[st];
            else
                continue;
        }

        /* Fast path: memcmp chunks against LUT */
        uint32_t s = 0;
        uint32_t p = pos;
        while (s < num_samples) {
            uint32_t chunk = PRBS_LEN - p;
            if (chunk > num_samples - s)
                chunk = num_samples - s;
            if (memcmp(&blk[s * 2], &prbs_lut[p], chunk * SAMPLE_SIZE) == 0) {
                s += chunk;
                p = (p + chunk) % PRBS_LEN;
            } else {
                /* Binary search for first mismatch in chunk */
                uint32_t lo = 0, hi = chunk;
                while (hi - lo > 1) {
                    uint32_t mid = lo + (hi - lo) / 2;
                    if (memcmp(&blk[(s + lo) * 2], &prbs_lut[p + lo],
                               (mid - lo) * SAMPLE_SIZE) == 0)
                        lo = mid;
                    else
                        hi = mid;
                }
                /* lo is the first mismatching sample */
                uint32_t i = lo;
                uint16_t rx_i = (uint16_t)blk[(s + i) * 2] >> 4;
                if (errors == 0) {
                    uint16_t exp_i = (uint16_t)prbs_lut[p + i].i >> 4;
                    fprintf(stderr, "ERR at pos=%u: got I=%03x exp I=%03x\n",
                            p + i, rx_i, exp_i);
                }
                errors++;

                /* Drain blocks until close to write head */
                uint32_t behind = (r.hw_wr >= r.rd)
                    ? (r.hw_wr - r.rd)
                    : (rx_buf_size - r.rd + r.hw_wr);
                while (behind > block_size * 2) {
                    if (read(fd, &r, sizeof(r)) != sizeof(r))
                        goto out;
                    behind = (r.hw_wr >= r.rd)
                        ? (r.hw_wr - r.rd)
                        : (rx_buf_size - r.rd + r.hw_wr);
                }
                /* Let normal initial sync handle the next block */
                p = -1;
                goto next_block;
            }
        }
    next_block:
        pos = p;
        samples += num_samples;

        struct timespec t1;
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double elapsed = (t1.tv_sec - t0.tv_sec) +
                         (t1.tv_nsec - t0.tv_nsec) * 1e-9;
        if (elapsed >= 1.0) {
            total_errors += errors;
            double msps = (double)samples / elapsed / 1e6;
            fprintf(stderr, "PRBS: %.3f MSPS  errors=%llu  total=%llu\n",
                    msps, (unsigned long long)errors,
                    (unsigned long long)total_errors);
            errors = 0;
            samples = 0;
            t0 = t1;
        }
    }

out:
    munmap(tx_map, tx_buf_size);
    munmap(rx_map, rx_buf_size);
    close(fd);
    return 0;
}

int main(int argc, char **argv) {
    typedef enum { MODE_TCP, MODE_UDP } tx_mode_t;
    tx_mode_t mode;
    int port;
    char host[64] = {0};

    if (argc == 2 && strcmp(argv[1], "--test") == 0) {
        return test();
    } else if (argc == 3 && strcmp(argv[1], "--rx-tcp") == 0) {
        mode = MODE_TCP;
        port = atoi(argv[2]);
    } else if (argc == 3 && strcmp(argv[1], "--rx-udp") == 0) {
        mode = MODE_UDP;
        char *colon = strrchr(argv[2], ':');
        if (!colon) {
            fprintf(stderr, "Expected HOST:PORT\n");
            return 1;
        }
        *colon = '\0';
        strncpy(host, argv[2], sizeof(host) - 1);
        port = atoi(colon + 1);
    } else if ((argc == 3 || argc == 5) && strcmp(argv[1], "--tx-tcp") == 0) {
        double depth = 0;
        if (argc == 5 && strcmp(argv[3], "--tx-depth") == 0)
            depth = atof(argv[4]);
        return receive_to_tx(atoi(argv[2]), depth);
    } else if (argc == 3 && strcmp(argv[1], "--membench") == 0) {
        return membench(atoi(argv[2]));
    } else if (argc == 2 && strcmp(argv[1], "--loopback") == 0) {
        return loopback_test();
    } else if (argc == 2 && strcmp(argv[1], "--prbs") == 0) {
        return prbs_test();
    } else {
        fprintf(stderr,
                "Usage: %s --rx-tcp PORT\n"
                "       %s --rx-udp HOST:PORT\n"
                "       %s --tx-tcp PORT [--tx-depth MSAMPLES]\n"
                "       %s --membench LOOPS\n"
                "       %s --prbs\n",
                argv[0], argv[0], argv[0], argv[0], argv[0]);
        return 1;
    }

    struct rxbuf rx;
    if (rxbuf_open(&rx) < 0)
        return 1;

    pthread_t stats_thr;
    pthread_create(&stats_thr, NULL, &status_thread, NULL);

    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(0, &cpuset);
    pthread_setaffinity_np(stats_thr, sizeof(cpuset), &cpuset);
    CPU_ZERO(&cpuset);
    CPU_SET(1, &cpuset);
    sched_setaffinity(0, sizeof(cpuset), &cpuset);

    int ret;
    if (mode == MODE_TCP)
        ret = send_using_tcp(&rx, port);
    else
        ret = send_using_udp(&rx, host, port);

    rxbuf_close(&rx);
    return ret;
}
