#ifndef AD9361_NET_H
#define AD9361_NET_H

#include <netinet/in.h>
#include <stddef.h>
#include <stdint.h>

#define DATAGRAM_SIZE 1472
#define SOCK_BUF_BYTES (8 << 20) // 8 MiB SO_SNDBUF / SO_RCVBUF

int tcp_send(int fd, const void *buf, size_t len);
int tcp_recv_full(int fd, void *buf, size_t len);
int udp_send_ring(int sock, struct sockaddr_in *dest, const uint8_t *data, uint32_t len);

/* Bind and listen on PORT; returns the server fd or -1 on error.
 * role is used in the log message only. Call once at startup. */
int tcp_listen(int port, const char *role);

/* Accept one client from SERVER, configure socket options, log the connection.
 * sndbuf/rcvbuf set SO_SNDBUF/SO_RCVBUF if > 0; nodelay enables TCP_NODELAY if non-zero.
 * Returns client fd or -1 on error. */
int tcp_accept(int server, int sndbuf, int rcvbuf, int nodelay, const char *role);

#endif
