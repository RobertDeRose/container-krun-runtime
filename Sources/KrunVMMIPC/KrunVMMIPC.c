#include "KrunVMMIPC.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <string.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

struct krun_vmm_request {
    uint32_t opcode;
    uint32_t port;
};

static int32_t neg_errno(void) {
    return errno == 0 ? -EIO : -errno;
}

static int set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0) {
        return -1;
    }
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static int send_flags(void) {
#ifdef MSG_NOSIGNAL
    return MSG_NOSIGNAL;
#else
    return 0;
#endif
}

static int32_t send_all(int fd, const void *buffer, size_t length) {
    const char *cursor = buffer;
    while (length > 0) {
        ssize_t written = send(fd, cursor, length, send_flags());
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            return neg_errno();
        }
        if (written == 0) {
            return -EIO;
        }
        cursor += written;
        length -= (size_t)written;
    }
    return 0;
}

// Read exactly `length` bytes from a stream. A clean EOF before any bytes are
// read is reported as 0 so callers can distinguish channel closure. EOF after a
// partial message is a reset because the fixed-size protocol frame is corrupt.
static int32_t recv_all(int fd, void *buffer, size_t length) {
    char *cursor = buffer;
    size_t received_total = 0;
    while (received_total < length) {
        ssize_t received = recv(fd, cursor + received_total, length - received_total, 0);
        if (received < 0) {
            if (errno == EINTR) {
                continue;
            }
            return neg_errno();
        }
        if (received == 0) {
            return received_total == 0 ? 0 : -ECONNRESET;
        }
        received_total += (size_t)received;
    }
    return 1;
}

int32_t krun_vmm_ipc_socketpair(int32_t fds[2]) {
    if (fds == NULL) {
        return -EINVAL;
    }

    int pair[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) < 0) {
        return neg_errno();
    }

#ifdef SO_NOSIGPIPE
    int enabled = 1;
    if (setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) < 0 ||
        setsockopt(pair[1], SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) < 0) {
        int saved = errno;
        close(pair[0]);
        close(pair[1]);
        errno = saved;
        return neg_errno();
    }
#endif

    if (set_cloexec(pair[0]) < 0 || set_cloexec(pair[1]) < 0) {
        int saved = errno;
        close(pair[0]);
        close(pair[1]);
        errno = saved;
        return neg_errno();
    }

    fds[0] = pair[0];
    fds[1] = pair[1];
    return 0;
}

static int set_nosigpipe(int fd) {
#ifdef SO_NOSIGPIPE
    int enabled = 1;
    return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
#else
    (void)fd;
    return 0;
#endif
}

static int unix_address(const char *path, struct sockaddr_un *address) {
    if (path == NULL || strlen(path) >= sizeof(address->sun_path)) {
        errno = path == NULL ? EINVAL : ENAMETOOLONG;
        return -1;
    }
    memset(address, 0, sizeof(*address));
    address->sun_family = AF_UNIX;
    strcpy(address->sun_path, path);
    return 0;
}

// A named endpoint for a helper that cannot inherit the socket pair, such as
// one launchd starts. Only the owner may connect; accept also checks the peer.
int32_t krun_vmm_ipc_listen(const char *path, int32_t *listen_fd) {
    struct sockaddr_un address;
    if (listen_fd == NULL || unix_address(path, &address) < 0) {
        return listen_fd == NULL ? -EINVAL : neg_errno();
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return neg_errno();
    }
    (void)unlink(path);
    mode_t old_mask = umask(0077);
    int bound = bind(fd, (struct sockaddr *)&address, sizeof(address));
    umask(old_mask);
    if (bound < 0 || listen(fd, 1) < 0 || set_cloexec(fd) < 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return neg_errno();
    }
    *listen_fd = fd;
    return 0;
}

int32_t krun_vmm_ipc_accept(int32_t listen_fd, int32_t timeout_ms, uint32_t peer_uid, int32_t *fd) {
    if (fd == NULL) {
        return -EINVAL;
    }
    struct pollfd ready = {.fd = listen_fd, .events = POLLIN};
    int polled = poll(&ready, 1, timeout_ms);
    if (polled < 0) {
        return neg_errno();
    }
    if (polled == 0) {
        return -ETIMEDOUT;
    }
    int connected = accept(listen_fd, NULL, NULL);
    if (connected < 0) {
        return neg_errno();
    }
    uid_t uid = (uid_t)-1;
    gid_t gid = (gid_t)-1;
    if (getpeereid(connected, &uid, &gid) < 0 || uid != (uid_t)peer_uid) {
        int saved = uid != (uid_t)peer_uid ? EPERM : errno;
        close(connected);
        errno = saved;
        return neg_errno();
    }
    if (set_nosigpipe(connected) < 0 || set_cloexec(connected) < 0) {
        int saved = errno;
        close(connected);
        errno = saved;
        return neg_errno();
    }
    *fd = connected;
    return 0;
}

int32_t krun_vmm_ipc_connect(const char *path, int32_t *fd) {
    struct sockaddr_un address;
    if (fd == NULL || unix_address(path, &address) < 0) {
        return fd == NULL ? -EINVAL : neg_errno();
    }
    int connected = socket(AF_UNIX, SOCK_STREAM, 0);
    if (connected < 0) {
        return neg_errno();
    }
    if (connect(connected, (struct sockaddr *)&address, sizeof(address)) < 0
        || set_nosigpipe(connected) < 0) {
        int saved = errno;
        close(connected);
        errno = saved;
        return neg_errno();
    }
    *fd = connected;
    return 0;
}

int32_t krun_vmm_ipc_send_request(int32_t fd, uint32_t opcode, uint32_t port) {
    struct krun_vmm_request request = {
        .opcode = htonl(opcode),
        .port = htonl(port),
    };
    return send_all(fd, &request, sizeof(request));
}

int32_t krun_vmm_ipc_recv_request(int32_t fd, uint32_t *opcode, uint32_t *port) {
    if (opcode == NULL || port == NULL) {
        return -EINVAL;
    }

    struct krun_vmm_request request;
    int32_t result = recv_all(fd, &request, sizeof(request));
    if (result <= 0) {
        return result;
    }

    *opcode = ntohl(request.opcode);
    *port = ntohl(request.port);
    return 1;
}

int32_t krun_vmm_ipc_send_response(int32_t fd, int32_t status, int32_t passed_fd) {
    uint32_t wire_status = htonl((uint32_t)status);
    struct iovec iov = {
        .iov_base = &wire_status,
        .iov_len = sizeof(wire_status),
    };
    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;

    char control[CMSG_SPACE(sizeof(int))];
    if (passed_fd >= 0) {
        memset(control, 0, sizeof(control));
        message.msg_control = control;
        message.msg_controllen = sizeof(control);
        struct cmsghdr *header = CMSG_FIRSTHDR(&message);
        header->cmsg_level = SOL_SOCKET;
        header->cmsg_type = SCM_RIGHTS;
        header->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(header), &passed_fd, sizeof(passed_fd));
    }

    ssize_t written;
    do {
        written = sendmsg(fd, &message, send_flags());
    } while (written < 0 && errno == EINTR);
    if (written < 0) {
        return neg_errno();
    }
    if (written == 0) {
        return -EIO;
    }
    if ((size_t)written == sizeof(wire_status)) {
        return 0;
    }
    return send_all(
        fd,
        ((const char *)&wire_status) + written,
        sizeof(wire_status) - (size_t)written
    );
}

int32_t krun_vmm_ipc_recv_response(int32_t fd, int32_t *status, int32_t *passed_fd) {
    if (status == NULL || passed_fd == NULL) {
        return -EINVAL;
    }

    uint32_t wire_status = 0;
    struct iovec iov = {
        .iov_base = &wire_status,
        .iov_len = sizeof(wire_status),
    };
    char control[CMSG_SPACE(sizeof(int))];
    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control;
    message.msg_controllen = sizeof(control);

    ssize_t received;
    do {
        received = recvmsg(fd, &message, 0);
    } while (received < 0 && errno == EINTR);
    if (received < 0) {
        return neg_errno();
    }
    if (received == 0) {
        return -ECONNRESET;
    }
    if ((size_t)received > sizeof(wire_status)) {
        return -EPROTO;
    }

    int received_fd = -1;
    for (struct cmsghdr *header = CMSG_FIRSTHDR(&message); header != NULL;
         header = CMSG_NXTHDR(&message, header)) {
        if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS) {
            continue;
        }
        size_t payload = header->cmsg_len - CMSG_LEN(0);
        size_t count = payload / sizeof(int);
        int *descriptors = (int *)CMSG_DATA(header);
        for (size_t index = 0; index < count; index++) {
            if (received_fd < 0) {
                received_fd = descriptors[index];
            } else {
                close(descriptors[index]);
            }
        }
    }

    if ((message.msg_flags & MSG_CTRUNC) != 0) {
        if (received_fd >= 0) {
            close(received_fd);
        }
        return -EMSGSIZE;
    }

    if ((size_t)received < sizeof(wire_status)) {
        int32_t result = recv_all(
            fd,
            ((char *)&wire_status) + received,
            sizeof(wire_status) - (size_t)received
        );
        if (result <= 0) {
            if (received_fd >= 0) {
                close(received_fd);
            }
            return result == 0 ? -ECONNRESET : result;
        }
    }

    int32_t decoded_status = (int32_t)ntohl(wire_status);
    if (decoded_status == 0 && received_fd < 0) {
        return -EPROTO;
    }
    if (decoded_status != 0 && received_fd >= 0) {
        close(received_fd);
        received_fd = -1;
    }

    *status = decoded_status;
    *passed_fd = received_fd;
    return 0;
}
