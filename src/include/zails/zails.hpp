#ifndef ZAILS_ZAILS_HPP
#define ZAILS_ZAILS_HPP

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "zails.h"

namespace zails {

using HandlerResult = zails_handler_result_t;
using NativeHandlerFn = zails_native_handler_fn;
using Frame = zails_frame_t;

namespace runtime {
static constexpr uint32_t abi_version = ZAILS_ABI_VERSION;
static constexpr size_t max_frame_payload_bytes = ZAILS_MAX_FRAME_PAYLOAD_BYTES;
} // namespace runtime

namespace errors {
static constexpr zails_server_error_t ok = ZAILS_OK;
static constexpr zails_server_error_t malformed_message = ZAILS_MALFORMED_MESSAGE;
static constexpr zails_server_error_t message_too_large = ZAILS_MESSAGE_TOO_LARGE;
static constexpr zails_server_error_t handler_failed = ZAILS_HANDLER_FAILED;
} // namespace errors

namespace handlers {

inline HandlerResult ok(size_t len) {
    return zails_ok(len);
}

inline HandlerResult err(zails_server_error_t error_code) {
    return zails_err(error_code);
}

} // namespace handlers

namespace foreign {

static constexpr uint32_t frame_magic = ZAILS_FRAME_MAGIC;
static constexpr uint16_t frame_version = ZAILS_FRAME_VERSION;
static constexpr size_t frame_header_bytes = ZAILS_FRAME_HEADER_BYTES;

inline int decode_header(
    const uint8_t* header,
    size_t header_len,
    Frame* out_frame,
    uint32_t* out_payload_len
) {
    return zails_decode_frame_header(header, header_len, out_frame, out_payload_len);
}

inline int decode(const uint8_t* bytes, size_t bytes_len, Frame* out_frame) {
    return zails_decode_frame(bytes, bytes_len, out_frame);
}

inline int encode_response(
    uint8_t message_type,
    uint64_t request_id,
    zails_server_error_t error_code,
    const uint8_t* payload,
    size_t payload_len,
    uint8_t* out,
    size_t out_cap,
    size_t* out_len
) {
    return zails_encode_response(
        message_type,
        request_id,
        error_code,
        payload,
        payload_len,
        out,
        out_cap,
        out_len
    );
}

inline int encode_request(
    uint8_t message_type,
    uint64_t request_id,
    const uint8_t* payload,
    size_t payload_len,
    uint8_t* out,
    size_t out_cap,
    size_t* out_len
) {
    return zails_encode_request(
        message_type,
        request_id,
        payload,
        payload_len,
        out,
        out_cap,
        out_len
    );
}

} // namespace foreign

namespace models {

class JsonView {
public:
    JsonView(const uint8_t* data, size_t len) : data_(data), len_(len) {}

    bool contains(const char* needle) const {
        if (needle == 0) return false;
        const size_t needle_len = strlen(needle);
        if (needle_len == 0 || needle_len > len_) return false;

        for (size_t i = 0; i <= len_ - needle_len; ++i) {
            if (memcmp(data_ + i, needle, needle_len) == 0) return true;
        }
        return false;
    }

    bool string_equals(const char* field, const char* value) const {
        char pattern[160];
        const int written = snprintf_field_string(pattern, sizeof(pattern), field, value);
        return written > 0 && (size_t)written < sizeof(pattern) && contains(pattern);
    }

    bool int_equals(const char* field, int64_t value) const {
        char pattern[96];
        const int written = snprintf_field_int(pattern, sizeof(pattern), field, value);
        return written > 0 && (size_t)written < sizeof(pattern) && contains(pattern);
    }

    bool uint_equals(const char* field, uint64_t value) const {
        char pattern[96];
        const int written = snprintf_field_uint(pattern, sizeof(pattern), field, value);
        return written > 0 && (size_t)written < sizeof(pattern) && contains(pattern);
    }

    bool bool_equals(const char* field, bool value) const {
        char pattern[96];
        const int written = snprintf_field_bool(pattern, sizeof(pattern), field, value);
        return written > 0 && (size_t)written < sizeof(pattern) && contains(pattern);
    }

    const uint8_t* data() const { return data_; }
    size_t size() const { return len_; }

private:
    static int append_literal(char* out, size_t cap, size_t* pos, const char* literal) {
        const size_t literal_len = strlen(literal);
        if (*pos + literal_len >= cap) return -1;
        memcpy(out + *pos, literal, literal_len);
        *pos += literal_len;
        out[*pos] = 0;
        return 0;
    }

    static int append_i64(char* out, size_t cap, size_t* pos, int64_t value) {
        char digits[32];
        bool negative = value < 0;
        uint64_t magnitude;
        if (negative) {
            magnitude = (uint64_t)(-(value + 1)) + 1;
        } else {
            magnitude = (uint64_t)value;
        }

        size_t index = sizeof(digits);
        do {
            digits[--index] = (char)('0' + (magnitude % 10));
            magnitude /= 10;
        } while (magnitude != 0);

        if (negative) digits[--index] = '-';
        const size_t len = sizeof(digits) - index;
        if (*pos + len >= cap) return -1;
        memcpy(out + *pos, digits + index, len);
        *pos += len;
        out[*pos] = 0;
        return 0;
    }

    static int append_u64(char* out, size_t cap, size_t* pos, uint64_t value) {
        char digits[32];
        size_t index = sizeof(digits);
        do {
            digits[--index] = (char)('0' + (value % 10));
            value /= 10;
        } while (value != 0);

        const size_t len = sizeof(digits) - index;
        if (*pos + len >= cap) return -1;
        memcpy(out + *pos, digits + index, len);
        *pos += len;
        out[*pos] = 0;
        return 0;
    }

    static int append_field_prefix(char* out, size_t cap, size_t* pos, const char* field) {
        return append_literal(out, cap, pos, "\"") ||
               append_literal(out, cap, pos, field) ||
               append_literal(out, cap, pos, "\":");
    }

    static int snprintf_field_string(char* out, size_t cap, const char* field, const char* value) {
        size_t pos = 0;
        if (append_field_prefix(out, cap, &pos, field) != 0) return -1;
        if (append_literal(out, cap, &pos, "\"") != 0) return -1;
        if (append_literal(out, cap, &pos, value) != 0) return -1;
        if (append_literal(out, cap, &pos, "\"") != 0) return -1;
        return (int)pos;
    }

    static int snprintf_field_int(char* out, size_t cap, const char* field, int64_t value) {
        size_t pos = 0;
        if (append_field_prefix(out, cap, &pos, field) != 0) return -1;
        if (append_i64(out, cap, &pos, value) != 0) return -1;
        return (int)pos;
    }

    static int snprintf_field_uint(char* out, size_t cap, const char* field, uint64_t value) {
        size_t pos = 0;
        if (append_field_prefix(out, cap, &pos, field) != 0) return -1;
        if (append_u64(out, cap, &pos, value) != 0) return -1;
        return (int)pos;
    }

    static int snprintf_field_bool(char* out, size_t cap, const char* field, bool value) {
        size_t pos = 0;
        if (append_field_prefix(out, cap, &pos, field) != 0) return -1;
        if (append_literal(out, cap, &pos, value ? "true" : "false") != 0) return -1;
        return (int)pos;
    }

    const uint8_t* data_;
    size_t len_;
};

} // namespace models

} // namespace zails

#endif
