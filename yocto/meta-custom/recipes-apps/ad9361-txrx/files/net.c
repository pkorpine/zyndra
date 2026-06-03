#define _GNU_SOURCE
#include "net.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int tcp_send(int fd, const void *buf, size_t len) {
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

// Receive exactly len bytes; -1 on error or peer disconnect.
int tcp_recv_full(int fd, void *buf, size_t len) {
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
            return -1;
        p += n;
        len -= n;
    }
    return 0;
}

// Chunk data into DATAGRAM_SIZE UDP packets; carries leftover bytes across calls.
int udp_send_ring(int sock, struct sockaddr_in *dest, const uint8_t *data, uint32_t len) {
    static uint8_t s_wrap_buf[DATAGRAM_SIZE];
    static uint32_t s_wrap_pos = 0;

    struct mmsghdr msgs[64];
    struct iovec iovs[64];
    int count = 0;

    if (s_wrap_pos > 0) {
        uint32_t need = DATAGRAM_SIZE - s_wrap_pos;
        memcpy(s_wrap_buf + s_wrap_pos, data, need);
        data += need;
        len -= need;

        iovs[0].iov_base = s_wrap_buf;
        iovs[0].iov_len = DATAGRAM_SIZE;
        msgs[0].msg_hdr = (struct msghdr){
            .msg_iov = &iovs[0],
            .msg_iovlen = 1,
            .msg_name = dest,
            .msg_namelen = sizeof(*dest),
        };
        count++;
        s_wrap_pos = 0;
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
        memcpy(s_wrap_buf, data, len);
        s_wrap_pos = len;
    }

    return 0;
}

int tcp_listen(int port, const char *role) {
    int server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0) {
        perror("socket");
        return -1;
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
        return -1;
    }
    listen(server, 1);
    fprintf(stderr, "%s: listening on port %d\n", role, port);
    return server;
}

int tcp_accept(int server, int sndbuf, int rcvbuf, int nodelay, const char *role) {
    fprintf(stderr, "Waiting for %s connection...\n", role);
    int client = accept(server, NULL, NULL);
    if (client < 0) {
        perror("accept");
        return -1;
    }
    fprintf(stderr, "%s client connected\n", role);

    int one = 1;
    if (sndbuf > 0)
        setsockopt(client, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
    if (rcvbuf > 0)
        setsockopt(client, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    if (nodelay)
        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    return client;
}
