const std = @import("std");
const net = std.net;
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
});

/// OpenSSL-based TLS implementation
/// Requires: libssl-dev or openssl-devel package
/// Build with: exe.linkSystemLibrary("ssl"); exe.linkSystemLibrary("crypto"); exe.linkLibC();

pub const TlsContext = struct {
    ctx: *c.SSL_CTX,
    allocator: Allocator,

    pub fn init(allocator: Allocator, cert_path: []const u8, key_path: []const u8) !TlsContext {
        // Initialize OpenSSL
        _ = c.SSL_library_init();
        c.SSL_load_error_strings();
        _ = c.OpenSSL_add_all_algorithms();

        // Create TLS context (server mode, TLS 1.2+)
        const method = c.TLS_server_method();
        const ctx = c.SSL_CTX_new(method) orelse return error.TlsContextCreationFailed;
        errdefer c.SSL_CTX_free(ctx);

        // Set minimum TLS version to 1.2
        _ = c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_2_VERSION);

        // Load certificate
        const cert_z = try allocator.dupeZ(u8, cert_path);
        defer allocator.free(cert_z);

        if (c.SSL_CTX_use_certificate_file(ctx, cert_z.ptr, c.SSL_FILETYPE_PEM) != 1) {
            std.log.err("Failed to load certificate: {s}", .{cert_path});
            printOpenSslError();
            return error.CertificateLoadFailed;
        }

        // Load private key
        const key_z = try allocator.dupeZ(u8, key_path);
        defer allocator.free(key_z);

        if (c.SSL_CTX_use_PrivateKey_file(ctx, key_z.ptr, c.SSL_FILETYPE_PEM) != 1) {
            std.log.err("Failed to load private key: {s}", .{key_path});
            printOpenSslError();
            return error.PrivateKeyLoadFailed;
        }

        // Verify private key matches certificate
        if (c.SSL_CTX_check_private_key(ctx) != 1) {
            std.log.err("Private key does not match certificate", .{});
            return error.PrivateKeyMismatch;
        }

        std.log.info("TLS initialized with certificate: {s}", .{cert_path});

        return TlsContext{
            .ctx = ctx,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TlsContext) void {
        c.SSL_CTX_free(self.ctx);
        c.EVP_cleanup();
    }

    pub fn acceptConnection(self: *TlsContext, stream: net.Stream) !TlsConnection {
        const ssl = c.SSL_new(self.ctx) orelse return error.SslCreationFailed;
        errdefer c.SSL_free(ssl);

        // Attach socket to SSL
        if (c.SSL_set_fd(ssl, stream.handle) != 1) {
            printOpenSslError();
            return error.SslSetFdFailed;
        }

        // Perform TLS handshake
        const result = c.SSL_accept(ssl);
        if (result != 1) {
            const err = c.SSL_get_error(ssl, result);
            std.log.err("TLS handshake failed: error code {}", .{err});
            printOpenSslError();
            return error.TlsHandshakeFailed;
        }

        std.log.debug("TLS handshake completed", .{});

        return TlsConnection{
            .ssl = ssl,
            .stream = stream,
        };
    }

    fn printOpenSslError() void {
        var err = c.ERR_get_error();
        while (err != 0) : (err = c.ERR_get_error()) {
            var buf: [256]u8 = undefined;
            c.ERR_error_string_n(err, &buf, buf.len);
            std.log.err("OpenSSL: {s}", .{std.mem.sliceTo(&buf, 0)});
        }
    }
};

pub const TlsConnection = struct {
    ssl: *c.SSL,
    stream: net.Stream,

    pub fn read(self: *TlsConnection, buffer: []u8) !usize {
        const result = c.SSL_read(self.ssl, buffer.ptr, @intCast(buffer.len));

        if (result <= 0) {
            const err = c.SSL_get_error(self.ssl, result);
            return switch (err) {
                c.SSL_ERROR_ZERO_RETURN => 0, // Clean shutdown
                c.SSL_ERROR_WANT_READ => error.WouldBlock,
                c.SSL_ERROR_WANT_WRITE => error.WouldBlock,
                c.SSL_ERROR_SYSCALL => error.SystemError,
                else => error.TlsReadError,
            };
        }

        return @intCast(result);
    }

    pub fn writeAll(self: *TlsConnection, buffer: []const u8) !void {
        var written: usize = 0;

        while (written < buffer.len) {
            const result = c.SSL_write(self.ssl, buffer[written..].ptr, @intCast(buffer.len - written));

            if (result <= 0) {
                const err = c.SSL_get_error(self.ssl, result);
                return switch (err) {
                    c.SSL_ERROR_WANT_WRITE => continue,
                    c.SSL_ERROR_WANT_READ => continue,
                    c.SSL_ERROR_SYSCALL => error.SystemError,
                    else => error.TlsWriteError,
                };
            }

            written += @intCast(result);
        }
    }

    pub fn close(self: *TlsConnection) void {
        // Shutdown TLS connection
        _ = c.SSL_shutdown(self.ssl);
        c.SSL_free(self.ssl);

        // Close underlying TCP socket
        self.stream.close();
    }
};

/// Client-side TLS context
pub const TlsClientContext = struct {
    ctx: *c.SSL_CTX,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !TlsClientContext {
        _ = c.SSL_library_init();
        c.SSL_load_error_strings();

        const method = c.TLS_client_method();
        const ctx = c.SSL_CTX_new(method) orelse return error.TlsContextCreationFailed;

        // Set minimum TLS version
        _ = c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_2_VERSION);

        // Load default CA certificates
        if (c.SSL_CTX_set_default_verify_paths(ctx) != 1) {
            std.log.warn("Failed to load default CA certificates", .{});
        }

        return TlsClientContext{
            .ctx = ctx,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TlsClientContext) void {
        c.SSL_CTX_free(self.ctx);
    }

    pub fn connectTo(self: *TlsClientContext, stream: net.Stream, hostname: []const u8) !TlsConnection {
        const ssl = c.SSL_new(self.ctx) orelse return error.SslCreationFailed;
        errdefer c.SSL_free(ssl);

        if (c.SSL_set_fd(ssl, stream.handle) != 1) {
            return error.SslSetFdFailed;
        }

        // Set SNI hostname
        const hostname_z = try self.allocator.dupeZ(u8, hostname);
        defer self.allocator.free(hostname_z);
        _ = c.SSL_set_tlsext_host_name(ssl, hostname_z.ptr);

        // Perform handshake
        if (c.SSL_connect(ssl) != 1) {
            TlsContext.printOpenSslError();
            return error.TlsHandshakeFailed;
        }

        std.log.debug("Client TLS handshake completed", .{});

        return TlsConnection{
            .ssl = ssl,
            .stream = stream,
        };
    }
};
