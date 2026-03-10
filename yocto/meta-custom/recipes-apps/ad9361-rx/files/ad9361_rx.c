#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sched.h>
#include <semaphore.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

// #define SEND_DIRECTLY

#define AXI_BASE 0x43C00000u
#define AXI_MAP_SIZE 0x10000u

#define CTRL_ENABLE (1u << 0)
#define CTRL_RESET (1u << 1)

struct ad9363_regs {
    volatile uint32_t info;        /* 0x00 */
    volatile uint32_t fifo;        /* 0x04 */
    volatile uint32_t ctrl;        /* 0x08 */
    volatile uint32_t drop_cnt;    /* 0x0C  dropped sample count */
    volatile uint32_t rx_buf_base; /* 0x10  DMA base address */
    volatile uint32_t rx_buf_size; /* 0x14  DMA buffer size in bytes */
    volatile uint32_t _pad;        /* 0x18  unused */
    volatile uint32_t rx_buf_wr;   /* 0x1C  current FPGA write pointer */
};

typedef enum { MODE_TCP, MODE_UDP } tx_mode_t;
static tx_mode_t s_mode;
static int s_port;
static char s_host[64];
static uint32_t s_buf_cnt;
static uint32_t s_buf_size;

#define SAMPLE_SIZE sizeof(uint32_t)
static sem_t sem_slot_used;
static sem_t sem_slot_free;
static uint8_t *tx_buf;

// Stats
static volatile uint32_t s_send_cnt = 0;
static volatile uint32_t s_pass_cnt = 0;
static volatile uint32_t s_buf_wait_cnt = 0;
static volatile uint32_t s_lost_bytes = 0;

// State
static volatile uint32_t connection_active = 0;

static int read_reserved_mem(const char *node, uint32_t *base, uint32_t *size) {
    char path[256];
    snprintf(path, sizeof(path), "/sys/firmware/devicetree/base/reserved-memory/%s/reg", node);

    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "ad9361_rx: open %s: %s\n", path, strerror(errno));
        return -1;
    }

    uint32_t cells[2];
    if (fread(cells, sizeof(cells), 1, f) != 1) {
        fprintf(stderr, "ad9361_rx: short read from %s\n", path);
        fclose(f);
        return -1;
    }
    fclose(f);

    *base = ntohl(cells[0]);
    *size = ntohl(cells[1]);
    return 0;
}

#define UDP_BATCH 32
static void *transmit_thread_udp(void *) {
    fprintf(stderr, "UDP THREAD START with %d buffers and %d batch\n", s_buf_cnt, UDP_BATCH);
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        fprintf(stderr, "ad9361_rx: socket: %s\n", strerror(errno));
        return NULL;
    }

    struct sockaddr_in dest = {
        .sin_family = AF_INET,
        .sin_port = htons(s_port),
    };

    if (inet_pton(AF_INET, s_host, &dest.sin_addr) != 1) {
        fprintf(stderr, "ad9361_rx: inet_pton failed\n");
        close(sock);
        return NULL;
    }

    // sysctl -w net.core.wmem_max=26214400
    // sysctl -w net.core.wmem_default=26214400
    int sndbuf = 8 * 1024 * 1024;
    setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));

    struct mmsghdr msgs[UDP_BATCH];
    struct iovec iovs[UDP_BATCH];

    // Prefill
    for (int n = 0; n < UDP_BATCH; n++) {
        iovs[n].iov_len = s_buf_size;
        msgs[n].msg_hdr.msg_iov = &iovs[n];
        msgs[n].msg_hdr.msg_iovlen = 1;
        msgs[n].msg_hdr.msg_name = &dest;
        msgs[n].msg_hdr.msg_namelen = sizeof(dest);
        msgs[n].msg_hdr.msg_control = NULL;
        msgs[n].msg_hdr.msg_controllen = 0;
        msgs[n].msg_hdr.msg_flags = 0;
    }

    int buf = 0;
    fprintf(stderr, "THREAD LOOP START\n");
    while (1) {
        for (int n = 0; n < UDP_BATCH; n++) {
            sem_wait(&sem_slot_used);
            iovs[n].iov_base = &tx_buf[s_buf_size * buf];
            buf = (buf + 1) % s_buf_cnt;
        }
        sendmmsg(sock, msgs, UDP_BATCH, 0);
        for (int n = 0; n < UDP_BATCH; n++) {
            sem_post(&sem_slot_free);
        }
        s_send_cnt += UDP_BATCH;
    }

    return NULL;
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

static void *transmit_thread_tcp(void *) {
    fprintf(stderr, "TCP THREAD START with %dx%d buffers\n", s_buf_cnt, s_buf_size);
    int server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0) {
        fprintf(stderr, "ad9361_rx: socket: %s\n", strerror(errno));
        return NULL;
    }

    int one = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_addr.s_addr = INADDR_ANY,
        .sin_port = htons(s_port),
    };

    if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        exit(1);
    }

    listen(server, 1);

    while (1) {
        fprintf(stderr, "Waiting for connection...\n");
        int client = accept(server, NULL, NULL);
        if (client < 0) {
            perror("accept");
            exit(1);
        }
        fprintf(stderr, "Client connected\n");
        connection_active = 1;

        // sysctl -w net.core.wmem_max=26214400
        // sysctl -w net.core.wmem_default=26214400
        int sndbuf = 8 * 1024 * 1024;
        setsockopt(client, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));

        int val;
        socklen_t len = sizeof(val);
        getsockopt(client, SOL_SOCKET, SO_SNDBUF, &val, &len);
        printf("actual sndbuf: %d\n", val);

        int buf_nr = 0;
        while (1) {
            sem_wait(&sem_slot_used);
#ifdef SEND_DIRECTLY
            uint32_t addr = *(uint32_t *)&tx_buf[s_buf_size * buf_nr];
            int res = tcp_send(client, (void *)addr, s_buf_size);
#else
            int res = tcp_send(client, &tx_buf[s_buf_size * buf_nr], s_buf_size);
#endif
            sem_post(&sem_slot_free);
            if (res < 0) {
                break;
            }
            buf_nr = (buf_nr + 1) % s_buf_cnt;
            s_send_cnt += 1;
        }
        connection_active = 0;

        fprintf(stderr, "Client disconnected\n");
        close(client);
    }

    return NULL;
}

static void *status_thread(void *) {
    uint32_t prev_send_cnt = 0;
    uint32_t prev_pass_cnt = 0;
    uint32_t prev_buf_wait_cnt = 0;
    uint32_t prev_lost_bytes = 0;
    struct timespec last_print;
    clock_gettime(CLOCK_MONOTONIC, &last_print);

    while (1) {
        usleep(1000 * 1000);

        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);

        double elapsed =
            (now.tv_sec - last_print.tv_sec) + (now.tv_nsec - last_print.tv_nsec) * 1e-9;

        uint32_t udp_send_cnt = s_send_cnt;
        uint32_t udp_pass_cnt = s_pass_cnt;
        uint32_t buf_wait_cnt = s_buf_wait_cnt;
        uint32_t lost_bytes = s_lost_bytes;

        float sps = ((float)((udp_send_cnt - prev_send_cnt) * s_buf_size / SAMPLE_SIZE)) / elapsed;
        fprintf(stderr, "send=%d pass=%d wait=%d inbuf=%d msps=%.2f lost=%d\n",
                udp_send_cnt - prev_send_cnt, udp_pass_cnt - prev_pass_cnt,
                buf_wait_cnt - prev_buf_wait_cnt, udp_pass_cnt - udp_send_cnt, sps / 1e6,
                lost_bytes - prev_lost_bytes);

        prev_send_cnt = udp_send_cnt;
        prev_pass_cnt = udp_pass_cnt;
        prev_buf_wait_cnt = buf_wait_cnt;
        prev_lost_bytes = lost_bytes;
        last_print = now;
    }

    return NULL;
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "--tcp") == 0) {
        s_mode = MODE_TCP;
        s_port = atoi(argv[2]);
        s_buf_cnt = 1024;
        s_buf_size = 32768;
    } else if (argc == 3 && strcmp(argv[1], "--udp") == 0) {
        s_mode = MODE_UDP;
        char *colon = strrchr(argv[2], ':');
        if (!colon) {
            fprintf(stderr, "Expected HOST:PORT\n");
            return 1;
        }
        *colon = '\0';
        strncpy(s_host, argv[2], sizeof(s_host) - 1);
        s_port = atoi(colon + 1);
        s_buf_cnt = 1024;
        s_buf_size = 1472;
    } else {
        fprintf(stderr,
                "Usage: %s --tcp PORT\n"
                "       %s --udp HOST:PORT\n",
                argv[0], argv[0]);
        return 1;
    }

    tx_buf = (uint8_t *)malloc(s_buf_cnt * s_buf_size);
    if (!tx_buf) {
        perror("malloc");
        return 1;
    }

    int ret = 1;
    pthread_t thread1;
    pthread_t thread2;
    cpu_set_t cpuset;

    sem_init(&sem_slot_used, 0, 0);
    sem_init(&sem_slot_free, 0, s_buf_cnt);
    if (s_mode == MODE_TCP)
        pthread_create(&thread1, NULL, &transmit_thread_tcp, NULL);
    else
        pthread_create(&thread1, NULL, &transmit_thread_udp, NULL);

    // Use single core, better utilization of L1 cache
    CPU_ZERO(&cpuset);
    CPU_SET(0, &cpuset);
    pthread_setaffinity_np(&thread1, sizeof(cpuset), &cpuset);
    sched_setaffinity(0, sizeof(cpuset), &cpuset);

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "ad9361_rx: open /dev/mem: %s\n", strerror(errno));
        goto err_free;
    }

    // Map control registers
    void *ctrl_map =
        mmap(NULL, AXI_MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)AXI_BASE);
    if (ctrl_map == MAP_FAILED) {
        fprintf(stderr, "ad9361_rx: mmap: %s\n", strerror(errno));
        goto err_close;
    }

    struct ad9363_regs *regs = (struct ad9363_regs *)ctrl_map;
    if ((regs->info >> 16) != 0xCAFEu) {
        fprintf(stderr, "ad9361_rx: unexpected INFO 0x%08X, wrong address?\n", regs->info);
        goto err_unmap;
    }

    // Map data region
    uint32_t rx_buf_base, rx_buf_size;
    if (read_reserved_mem("rx_buffer@1f000000", &rx_buf_base, &rx_buf_size) < 0)
        goto err_unmap;
    fprintf(stderr, "RX buffer: 0x%08X size 0x%08X\n", rx_buf_base, rx_buf_size);
    void *rx_map = mmap(NULL, rx_buf_size, PROT_READ, MAP_SHARED, fd, (off_t)rx_buf_base);
    if (rx_map == MAP_FAILED) {
        fprintf(stderr, "ad9361_rx: mmap rx_buf: %s\n", strerror(errno));
        goto err_unmap;
    }
    volatile uint8_t *rx_buf = (volatile uint8_t *)rx_map;

    if (regs->ctrl != 0) {
        // Stop any action before reset
        regs->ctrl = 0;
        usleep(100);
    }

    // Configure block
    regs->ctrl = CTRL_RESET;
    usleep(100);
    regs->rx_buf_base = rx_buf_base;
    regs->rx_buf_size = rx_buf_size;
    regs->ctrl = 0;
    usleep(100);
    regs->ctrl = CTRL_ENABLE;

    pthread_create(&thread2, NULL, &status_thread, NULL);

    int buf_nr = 0;
    uint8_t *buf = tx_buf;
    uint32_t rd_ptr = 0;
    while (1) {
        uint32_t wr_ptr = regs->rx_buf_wr;
        uint32_t bytes_available =
            (wr_ptr >= rd_ptr) ? (wr_ptr - rd_ptr) : (rx_buf_size - rd_ptr + wr_ptr);

        if (bytes_available < s_buf_size) {
            usleep(1);
            s_buf_wait_cnt++;
            continue;
        }
        int res = sem_trywait(&sem_slot_free);
        if (res != 0) {
            // Not able to get a slot
            s_lost_bytes += bytes_available;
            rd_ptr = wr_ptr;
            usleep(1);
            continue;
        }

#ifdef SEND_DIRECTLY
        uint32_t addr = (uint32_t)(rx_buf + rd_ptr);
        *(uint32_t *)buf = addr;
#else
        // Samples available before wrap
        uint32_t bytes_before_wrap = rx_buf_size - rd_ptr;
        if (bytes_before_wrap < s_buf_size) {
            // Copy first the tail
            memcpy(buf, (const uint8_t *)rx_buf + rd_ptr, bytes_before_wrap);
            uint32_t bytes_after_wrap = s_buf_size - bytes_before_wrap;
            // Copy then from the head
            memcpy(buf + bytes_before_wrap, (const uint8_t *)rx_buf, bytes_after_wrap);
        } else {
            // Single copy enough
            memcpy(buf, (const uint8_t *)rx_buf + rd_ptr, s_buf_size);
        }
#endif

        rd_ptr = (rd_ptr + s_buf_size) % rx_buf_size;
        sem_post(&sem_slot_used);
        buf_nr = (buf_nr + 1) % s_buf_cnt;
        buf = &tx_buf[buf_nr * s_buf_size];
        s_pass_cnt++;
    }

    ret = 0;

    munmap(rx_map, rx_buf_size);
err_unmap:
    munmap(ctrl_map, AXI_MAP_SIZE);
err_close:
    close(fd);
err_free:
    sem_destroy(&sem_slot_used);
    sem_destroy(&sem_slot_free);
    free(tx_buf);
    return ret;
}
