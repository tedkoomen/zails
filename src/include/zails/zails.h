#ifndef ZAILS_ZAILS_H
#define ZAILS_ZAILS_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ZAILS_ABI_VERSION 1u
#define ZAILS_FRAME_MAGIC 0x3146485aU
#define ZAILS_FRAME_VERSION 1u
#define ZAILS_FRAME_HEADER_BYTES 32u
#define ZAILS_MAX_FRAME_PAYLOAD_BYTES 8192u

typedef enum zails_server_error_t {
    ZAILS_OK = 0,
    ZAILS_CONNECTION_CLOSED = 1,
    ZAILS_CONNECTION_TIMEOUT = 2,
    ZAILS_CONNECTION_LIMIT_REACHED = 3,
    ZAILS_INVALID_HEADER = 10,
    ZAILS_MESSAGE_TOO_LARGE = 11,
    ZAILS_MALFORMED_MESSAGE = 12,
    ZAILS_UNKNOWN_MESSAGE_TYPE = 13,
    ZAILS_POOL_EXHAUSTED = 20,
    ZAILS_QUEUE_FULL = 21,
    ZAILS_OUT_OF_MEMORY = 22,
    ZAILS_HANDLER_NOT_FOUND = 30,
    ZAILS_HANDLER_FAILED = 31,
    ZAILS_HANDLER_TIMEOUT = 32,
    ZAILS_READ_FAILED = 40,
    ZAILS_WRITE_FAILED = 41,
} zails_server_error_t;

typedef enum zails_frame_kind_t {
    ZAILS_FRAME_REQUEST = 1,
    ZAILS_FRAME_RESPONSE = 2,
    ZAILS_FRAME_HEALTH = 3,
} zails_frame_kind_t;

typedef struct zails_handler_result_t {
    size_t len;
    uint8_t error_code;
} zails_handler_result_t;

typedef zails_handler_result_t (*zails_native_handler_fn)(
    const uint8_t* request_ptr,
    size_t request_len,
    uint8_t* response_ptr,
    size_t response_cap
);

typedef struct zails_frame_t {
    uint8_t kind;
    uint64_t request_id;
    uint8_t message_type;
    uint8_t error_code;
    const uint8_t* payload;
    size_t payload_len;
} zails_frame_t;

#ifdef __cplusplus
#define ZAILS_NATIVE_HANDLER(name) \
    extern "C" zails_handler_result_t name(const uint8_t* request_ptr, size_t request_len, uint8_t* response_ptr, size_t response_cap)
#else
#define ZAILS_NATIVE_HANDLER(name) \
    zails_handler_result_t name(const uint8_t* request_ptr, size_t request_len, uint8_t* response_ptr, size_t response_cap)
#endif

static inline zails_handler_result_t zails_ok(size_t len) {
    zails_handler_result_t result;
    result.len = len;
    result.error_code = (uint8_t)ZAILS_OK;
    return result;
}

static inline zails_handler_result_t zails_err(zails_server_error_t error_code) {
    zails_handler_result_t result;
    result.len = 0;
    result.error_code = (uint8_t)error_code;
    return result;
}

static inline uint16_t zails_read_le16(const uint8_t* p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static inline uint32_t zails_read_le32(const uint8_t* p) {
    return (uint32_t)p[0] |
           ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

static inline uint64_t zails_read_le64(const uint8_t* p) {
    uint64_t value = 0;
    for (size_t i = 0; i < 8; ++i) {
        value |= ((uint64_t)p[i]) << (i * 8);
    }
    return value;
}

static inline void zails_write_le16(uint8_t* p, uint16_t value) {
    p[0] = (uint8_t)(value & 0xff);
    p[1] = (uint8_t)((value >> 8) & 0xff);
}

static inline void zails_write_le32(uint8_t* p, uint32_t value) {
    p[0] = (uint8_t)(value & 0xff);
    p[1] = (uint8_t)((value >> 8) & 0xff);
    p[2] = (uint8_t)((value >> 16) & 0xff);
    p[3] = (uint8_t)((value >> 24) & 0xff);
}

static inline void zails_write_le64(uint8_t* p, uint64_t value) {
    for (size_t i = 0; i < 8; ++i) {
        p[i] = (uint8_t)((value >> (i * 8)) & 0xff);
    }
}

static inline int zails_decode_frame_header(
    const uint8_t* header,
    size_t header_len,
    zails_frame_t* out_frame,
    uint32_t* out_payload_len
) {
    if (header_len < ZAILS_FRAME_HEADER_BYTES) return ZAILS_MALFORMED_MESSAGE;
    if (zails_read_le32(header + 0) != ZAILS_FRAME_MAGIC) return ZAILS_INVALID_HEADER;
    if (zails_read_le16(header + 4) != ZAILS_FRAME_VERSION) return ZAILS_INVALID_HEADER;
    if (header[6] != ZAILS_FRAME_REQUEST &&
        header[6] != ZAILS_FRAME_RESPONSE &&
        header[6] != ZAILS_FRAME_HEALTH) {
        return ZAILS_MALFORMED_MESSAGE;
    }

    const uint32_t payload_len = zails_read_le32(header + 20);
    if (payload_len > ZAILS_MAX_FRAME_PAYLOAD_BYTES) return ZAILS_MESSAGE_TOO_LARGE;

    if (out_frame != 0) {
        out_frame->kind = header[6];
        out_frame->request_id = zails_read_le64(header + 8);
        out_frame->message_type = header[16];
        out_frame->error_code = header[17];
        out_frame->payload = 0;
        out_frame->payload_len = payload_len;
    }
    if (out_payload_len != 0) {
        *out_payload_len = payload_len;
    }
    return ZAILS_OK;
}

static inline int zails_decode_frame(
    const uint8_t* bytes,
    size_t bytes_len,
    zails_frame_t* out_frame
) {
    uint32_t payload_len = 0;
    const int header_result = zails_decode_frame_header(
        bytes,
        bytes_len,
        out_frame,
        &payload_len
    );
    if (header_result != ZAILS_OK) return header_result;
    if (bytes_len < ZAILS_FRAME_HEADER_BYTES + (size_t)payload_len) return ZAILS_MALFORMED_MESSAGE;

    if (out_frame != 0) {
        out_frame->payload = bytes + ZAILS_FRAME_HEADER_BYTES;
        out_frame->payload_len = payload_len;
    }
    return ZAILS_OK;
}

static inline int zails_encode_frame(
    const zails_frame_t* frame,
    uint8_t* out,
    size_t out_cap,
    size_t* out_len
) {
    if (frame == 0 || out == 0) return ZAILS_MALFORMED_MESSAGE;
    if (frame->payload_len > ZAILS_MAX_FRAME_PAYLOAD_BYTES) return ZAILS_MESSAGE_TOO_LARGE;

    const size_t total_len = ZAILS_FRAME_HEADER_BYTES + frame->payload_len;
    if (out_cap < total_len) return ZAILS_MESSAGE_TOO_LARGE;

    memset(out, 0, ZAILS_FRAME_HEADER_BYTES);
    zails_write_le32(out + 0, ZAILS_FRAME_MAGIC);
    zails_write_le16(out + 4, ZAILS_FRAME_VERSION);
    out[6] = frame->kind;
    zails_write_le64(out + 8, frame->request_id);
    out[16] = frame->message_type;
    out[17] = frame->error_code;
    zails_write_le32(out + 20, (uint32_t)frame->payload_len);
    if (frame->payload_len > 0 && frame->payload != 0) {
        memcpy(out + ZAILS_FRAME_HEADER_BYTES, frame->payload, frame->payload_len);
    }
    if (out_len != 0) {
        *out_len = total_len;
    }
    return ZAILS_OK;
}

static inline int zails_encode_response(
    uint8_t message_type,
    uint64_t request_id,
    zails_server_error_t error_code,
    const uint8_t* payload,
    size_t payload_len,
    uint8_t* out,
    size_t out_cap,
    size_t* out_len
) {
    zails_frame_t frame;
    frame.kind = ZAILS_FRAME_RESPONSE;
    frame.request_id = request_id;
    frame.message_type = message_type;
    frame.error_code = (uint8_t)error_code;
    frame.payload = payload;
    frame.payload_len = payload_len;
    return zails_encode_frame(&frame, out, out_cap, out_len);
}

static inline int zails_encode_request(
    uint8_t message_type,
    uint64_t request_id,
    const uint8_t* payload,
    size_t payload_len,
    uint8_t* out,
    size_t out_cap,
    size_t* out_len
) {
    zails_frame_t frame;
    frame.kind = ZAILS_FRAME_REQUEST;
    frame.request_id = request_id;
    frame.message_type = message_type;
    frame.error_code = (uint8_t)ZAILS_OK;
    frame.payload = payload;
    frame.payload_len = payload_len;
    return zails_encode_frame(&frame, out, out_cap, out_len);
}

#ifdef __cplusplus
}
#endif

#endif
