/* mock-zmq-server URL: stands for frama-c -server-zmq URL in the mock.
 * A real libzmq REP server (linked against the system libzmq.so.5, no
 * headers needed) speaking Frama-C's server_zmq protocol:
 *   GET id kernel.services.getConfig null -> first NONE (busy), then on
 *   POLL: DATA id {"version":"33.0",...};  SHUTDOWN -> NONE, exit.
 * Shipped like a why3 helper, so bundle_libs bundles libzmq as it does for
 * the real frama-c. */
#include <stdio.h>
#include <string.h>
#include <stddef.h>
typedef struct { unsigned char d[64]; } __attribute__((aligned(8))) zmq_msg_t;
void *zmq_ctx_new(void);
void *zmq_socket(void *, int);
int zmq_bind(void *, const char *);
int zmq_msg_init(zmq_msg_t *);
int zmq_msg_recv(zmq_msg_t *, void *, int);
void *zmq_msg_data(zmq_msg_t *);
size_t zmq_msg_size(zmq_msg_t *);
int zmq_msg_close(zmq_msg_t *);
int zmq_getsockopt(void *, int, void *, size_t *);
int zmq_send(void *, const void *, size_t, int);
#define ZMQ_REP 4
#define ZMQ_SNDMORE 2
#define ZMQ_RCVMORE 13

static int recv_parts(void *s, char parts[][256], int max) {
    int n = 0, more = 1;
    while (more) {
        zmq_msg_t m; zmq_msg_init(&m);
        if (zmq_msg_recv(&m, s, 0) < 0) return -1;
        size_t len = zmq_msg_size(&m); if (len > 255) len = 255;
        if (n < max) { memcpy(parts[n], zmq_msg_data(&m), len); parts[n][len] = 0; n++; }
        zmq_msg_close(&m);
        size_t sz = sizeof more; zmq_getsockopt(s, ZMQ_RCVMORE, &more, &sz);
    }
    return n;
}
static void send_parts(void *s, const char **p, int n) {
    for (int i = 0; i < n; i++) zmq_send(s, p[i], strlen(p[i]), i < n - 1 ? ZMQ_SNDMORE : 0);
}
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    void *s = zmq_socket(zmq_ctx_new(), ZMQ_REP);
    if (zmq_bind(s, argv[1]) != 0) { fprintf(stderr, "bind failed\n"); return 1; }
    printf("[server] ZeroMQ [%s] (mock)\n", argv[1]); fflush(stdout);
    char parts[8][256], pending[256] = "";
    for (;;) {
        int n = recv_parts(s, parts, 8);
        if (n <= 0) return 1;
        if (!strcmp(parts[0], "SHUTDOWN")) { const char *r[] = {"NONE"}; send_parts(s, r, 1); return 0; }
        if (!strcmp(parts[0], "GET") && n == 4 && !strcmp(parts[2], "kernel.services.getConfig")) {
            strcpy(pending, parts[1]); const char *r[] = {"NONE"}; send_parts(s, r, 1);
        } else if (!strcmp(parts[0], "GET") && n == 4) {
            const char *r[] = {"ERROR", parts[1], "unknown request"}; send_parts(s, r, 3);
        } else if (!strcmp(parts[0], "POLL") && pending[0]) {
            const char *r[] = {"DATA", pending, "{\"version\":\"33.0\",\"codename\":\"Arsenic\"}"};
            send_parts(s, r, 3); pending[0] = 0;
        } else { const char *r[] = {"NONE"}; send_parts(s, r, 1); }
    }
}
