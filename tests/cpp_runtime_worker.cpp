#include <zails/zails.hpp>

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int read_exact(int fd, void* data, size_t len) {
    uint8_t* cursor = (uint8_t*)data;
    size_t offset = 0;
    while (offset < len) {
        ssize_t n = read(fd, cursor + offset, len - offset);
        if (n == 0) return -1;
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        offset += (size_t)n;
    }
    return 0;
}

static int write_all(int fd, const void* data, size_t len) {
    const uint8_t* cursor = (const uint8_t*)data;
    size_t offset = 0;
    while (offset < len) {
        ssize_t n = write(fd, cursor + offset, len - offset);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        offset += (size_t)n;
    }
    return 0;
}

static int write_response(
    int fd,
    uint64_t request_id,
    uint8_t message_type,
    zails_server_error_t error_code,
    const uint8_t* payload,
    size_t payload_len
) {
    uint8_t frame[zails::foreign::frame_header_bytes + zails::runtime::max_frame_payload_bytes];
    size_t frame_len = 0;
    const int encode_result = zails::foreign::encode_response(
        message_type,
        request_id,
        error_code,
        payload,
        payload_len,
        frame,
        sizeof(frame),
        &frame_len
    );
    if (encode_result != ZAILS_OK) return -1;
    return write_all(fd, frame, frame_len);
}

int main(int argc, char** argv) {
    uint16_t port = 39091;
    if (argc > 1) {
        port = (uint16_t)strtoul(argv[1], NULL, 10);
    }

    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) return 2;

    int enabled = 1;
    (void)setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled));

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(port);

    if (bind(server_fd, (struct sockaddr*)&address, sizeof(address)) != 0) {
        close(server_fd);
        return 3;
    }
    if (listen(server_fd, 1) != 0) {
        close(server_fd);
        return 4;
    }

    int client_fd = accept(server_fd, NULL, NULL);
    if (client_fd < 0) {
        close(server_fd);
        return 5;
    }

    uint8_t header[zails::foreign::frame_header_bytes];
    uint8_t payload[zails::runtime::max_frame_payload_bytes];
    zails::Frame frame = {};
    uint32_t payload_len = 0;
    zails_server_error_t response_code = ZAILS_MALFORMED_MESSAGE;
    const uint8_t* response_payload = NULL;
    size_t response_len = 0;

    if (read_exact(client_fd, header, sizeof(header)) == 0 &&
        zails::foreign::decode_header(header, sizeof(header), &frame, &payload_len) == ZAILS_OK &&
        frame.kind == ZAILS_FRAME_REQUEST &&
        read_exact(client_fd, payload, payload_len) == 0) {
        const zails::models::JsonView model(payload, payload_len);
        const bool saw_trade =
            model.string_equals("symbol", "AAPL") &&
            model.int_equals("price", 15000) &&
            model.uint_equals("quantity", 25) &&
            model.bool_equals("active", true);

        if (saw_trade) {
            static const uint8_t ok[] = "cpp saw Trade model: symbol=AAPL price=15000 quantity=25 active=true";
            response_code = ZAILS_OK;
            response_payload = ok;
            response_len = sizeof(ok) - 1;
        }
    }

    (void)write_response(
        client_fd,
        frame.request_id,
        frame.message_type,
        response_code,
        response_payload,
        response_len
    );

    close(client_fd);
    close(server_fd);
    return response_code == ZAILS_OK ? 0 : 6;
}
