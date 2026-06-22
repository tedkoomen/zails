#!/usr/bin/env python3
"""Minimal out-of-process Zails foreign handler worker.

Run:
  python3 examples/python_foreign_worker.py 9001

Then register a Zig handler with:
  const Handler = zails.TcpForeignHandler(.{
      .message_type = 50,
      .host = "127.0.0.1",
      .port = 9001,
  });
"""

import socket
import struct
import sys


HEADER_BYTES = 32
MAGIC = 0x3146485A
VERSION = 1
KIND_REQUEST = 1
KIND_RESPONSE = 2
SERVER_ERROR_NONE = 0
SERVER_ERROR_MALFORMED = 12


def encode_frame(kind, request_id, message_type, error_code, payload):
    header = struct.pack(
        "<I H B B Q B B H I Q",
        MAGIC,
        VERSION,
        kind,
        0,
        request_id,
        message_type,
        error_code,
        0,
        len(payload),
        0,
    )
    return header + payload


def decode_frame(data):
    if len(data) != HEADER_BYTES:
        raise ValueError("short header")

    magic, version, kind, _flags, request_id, message_type, error_code, _reserved, payload_len, _tail = struct.unpack(
        "<I H B B Q B B H I Q",
        data,
    )
    if magic != MAGIC or version != VERSION or kind != KIND_REQUEST:
        raise ValueError("invalid frame")

    return request_id, message_type, error_code, payload_len


def read_exact(conn, size):
    chunks = bytearray()
    while len(chunks) < size:
        chunk = conn.recv(size - len(chunks))
        if not chunk:
            raise EOFError("connection closed")
        chunks.extend(chunk)
    return bytes(chunks)


def handle(payload):
    return payload.upper(), SERVER_ERROR_NONE


def serve(port):
    with socket.create_server(("127.0.0.1", port), reuse_port=False) as server:
        print(f"zails python foreign worker listening on 127.0.0.1:{port}", flush=True)
        while True:
            conn, _addr = server.accept()
            with conn:
                try:
                    header = read_exact(conn, HEADER_BYTES)
                    request_id, message_type, _error_code, payload_len = decode_frame(header)
                    payload = read_exact(conn, payload_len)
                    response, error_code = handle(payload)
                except Exception:
                    request_id = 0
                    message_type = 0
                    response = b""
                    error_code = SERVER_ERROR_MALFORMED

                conn.sendall(
                    encode_frame(
                        KIND_RESPONSE,
                        request_id,
                        message_type,
                        error_code,
                        response,
                    )
                )


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9001
    serve(port)
