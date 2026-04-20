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

/* Per-client session callback. Return value is ignored; the function returns
 * when the client disconnects or hits an error. */
typedef int (*tcp_session_fn)(int client, void *user);

/* Bind/listen on PORT, accept clients in a loop, run session() per client.
 * sndbuf/rcvbuf set SO_SNDBUF/SO_RCVBUF on accepted sockets if > 0.
 * tcp_nodelay enables TCP_NODELAY on accepted sockets if non-zero.
 * role is a short string for log messages ("RX", "TX", ...).
 * Returns non-zero on socket/bind error; otherwise loops forever. */
int tcp_serve(int port, int sndbuf, int rcvbuf, int tcp_nodelay, const char *role,
              tcp_session_fn session, void *user);

#endif
