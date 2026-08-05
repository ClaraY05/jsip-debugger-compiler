#include "caml/mlvalues.h"
#include "caml/memory.h"
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#endif

/* ------------------------------------------------------------------ *
 * The dump sink -- markers and records alike arrive through
 * [caml_wire_emit].  Chosen once at the first write:
 *
 *   VREPLAY_SOCK=<path>   Unix stream socket (falls through on failure)
 *   VREPLAY_FILE=<path>   that file, truncated
 *   neither               ./vreplay.dump
 *
 * Never stdout.  Writes are raw full-write loops, unbuffered and
 * verbatim (framing is the caller's job); MSG_NOSIGNAL keeps a
 * vanished listener from killing the program; any error warns once on
 * stderr and disables emission.  The only stub code touching the
 * environment or OS I/O -- the walker (snapshot.c) never writes.
 * ------------------------------------------------------------------ */
static int wire_fd = -2;               /* -2 not yet chosen, -1 disabled */
#ifndef _WIN32
static int wire_fd_is_socket = 0;      /* only the POSIX path has sockets */
#endif

static void wire_disable(const char *what, const char *detail)
{
    fprintf(stderr, "vreplay: %s %s (%s); dump disabled\n",
            what, detail, strerror(errno));
    wire_fd = -1;
}

static void wire_open_sink(void)
{
#ifndef _WIN32
    const char *sock = getenv("VREPLAY_SOCK");
    if (sock != NULL) {
        struct sockaddr_un addr;
        if (strlen(sock) < sizeof(addr.sun_path)) {
            int fd = socket(AF_UNIX, SOCK_STREAM, 0);
            memset(&addr, 0, sizeof(addr));
            addr.sun_family = AF_UNIX;
            strcpy(addr.sun_path, sock);
            if (fd >= 0
                && connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
                wire_fd = fd;
                wire_fd_is_socket = 1;
                return;
            }
            if (fd >= 0) close(fd);
        } else
            errno = ENAMETOOLONG;
        fprintf(stderr,
                "vreplay: cannot connect VREPLAY_SOCK %s (%s); "
                "falling back to a file\n",
                sock, strerror(errno));
    }
#endif
    const char *path = getenv("VREPLAY_FILE");
    if (path == NULL) path = "vreplay.dump";
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { wire_disable("cannot open", path); return; }
    wire_fd = fd;
}

static void wire_write(const char *buf, size_t len)
{
    if (wire_fd == -2) wire_open_sink();
    while (wire_fd >= 0 && len > 0) {
#ifdef _WIN32
        int n;                         /* MSVC has no ssize_t */
#else
        ssize_t n;
#endif
#ifndef _WIN32
        if (wire_fd_is_socket) n = send(wire_fd, buf, len, MSG_NOSIGNAL);
        else
#endif
            n = write(wire_fd, buf, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            wire_disable("write failed on", "the dump sink");
            return;
        }
        buf += n;
        len -= (size_t)n;
    }
}

/* external __wire_emit : string -> unit = "caml_wire_emit" */
CAMLprim value caml_wire_emit(value v_msg)
{
    CAMLparam1(v_msg);
    wire_write(String_val(v_msg), caml_string_length(v_msg));
    CAMLreturn(Val_unit);
}
