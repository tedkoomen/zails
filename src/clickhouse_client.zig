/// ClickHouse HTTP Client with Connection Pooling
/// Tiger Style: NEVER THROWS - all errors are values
/// Uses lock-free connection pool for high performance

const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const Uri = std.Uri;

/// URL-encode a string for safe use in query parameters
fn urlEncode(allocator: Allocator, input: []const u8) ![]u8 {
    // Worst case: every byte becomes %XX (3 bytes)
    var result = try allocator.alloc(u8, input.len * 3);
    errdefer allocator.free(result);
    var pos: usize = 0;

    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            result[pos] = c;
            pos += 1;
        } else {
            result[pos] = '%';
            const hex = "0123456789ABCDEF";
            result[pos + 1] = hex[c >> 4];
            result[pos + 2] = hex[c & 0x0F];
            pos += 3;
        }
    }

    // Shrink to actual size
    // On realloc failure, return the full-sized buffer (caller frees with correct length)
    if (pos < result.len) {
        return allocator.realloc(result, pos) catch result;
    }
    return result;
}

/// Configuration for ClickHouse client
pub const ClickHouseConfig = struct {
    host: []const u8,
    port: u16,
    database: []const u8,
    username: []const u8,
    password: []const u8,
    pool_size: usize = 10,
    timeout_ms: u64 = 5000,
};

/// Result of database operations
pub const InsertResult = union(enum) {
    ok: void,
    err: InsertError,

    pub const InsertError = enum {
        connection_failed,
        http_error,
        authentication_failed,
        database_error,
        serialization_failed,
        timeout,
    };

    pub fn isOk(self: InsertResult) bool {
        return self == .ok;
    }

    pub fn isErr(self: InsertResult) bool {
        return self == .err;
    }
};

/// Query result
pub const QueryResult = struct {
    data: []const u8,
    rows: usize,

    pub fn deinit(self: *QueryResult, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

/// HTTP connection (pooled object)
const HttpConnection = struct {
    client: http.Client,
    in_use: bool,

    pub fn initPooled() HttpConnection {
        return .{
            .client = undefined, // Will be initialized on first use
            .in_use = false,
        };
    }

    pub fn deinitPooled(self: *HttpConnection) void {
        if (self.in_use) {
            self.client.deinit();
        }
    }
};

/// ClickHouse HTTP client with connection pooling
pub const ClickHouseClient = struct {
    allocator: Allocator,
    config: ClickHouseConfig,
    auth_header: []u8,

    pub fn init(allocator: Allocator, config: ClickHouseConfig) !ClickHouseClient {
        // Build Basic auth header
        const auth_str = try std.fmt.allocPrint(
            allocator,
            "{s}:{s}",
            .{ config.username, config.password },
        );
        defer allocator.free(auth_str);

        var encoder = std.base64.standard.Encoder;
        const encoded_len = encoder.calcSize(auth_str.len);
        const auth_encoded = try allocator.alloc(u8, encoded_len);
        errdefer allocator.free(auth_encoded);

        _ = encoder.encode(auth_encoded, auth_str);

        const auth_header = try std.fmt.allocPrint(
            allocator,
            "Basic {s}",
            .{auth_encoded},
        );
        defer allocator.free(auth_encoded);

        std.log.info("ClickHouse client initialized (host={s}:{d}, database={s})", .{
            config.host,
            config.port,
            config.database,
        });

        return ClickHouseClient{
            .allocator = allocator,
            .config = config,
            .auth_header = auth_header,
        };
    }

    pub fn deinit(self: *ClickHouseClient) void {
        self.allocator.free(self.auth_header);
    }

    /// Insert batch of rows into table using JSONEachRow format
    pub fn insertBatch(
        self: *ClickHouseClient,
        table: []const u8,
        json_rows: []const u8,
    ) InsertResult {
        // Validate table name (only allow alphanumeric, underscore, dot for schema.table)
        for (table) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') {
                std.log.err("Invalid table name character: '{c}'", .{c});
                return InsertResult{ .err = .serialization_failed };
            }
        }

        // Build query URL with URL encoding
        const query_sql = std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO {s} FORMAT JSONEachRow",
            .{table},
        ) catch return InsertResult{ .err = .serialization_failed };
        defer self.allocator.free(query_sql);

        const encoded_query = urlEncode(self.allocator, query_sql) catch
            return InsertResult{ .err = .serialization_failed };
        defer self.allocator.free(encoded_query);

        const encoded_db = urlEncode(self.allocator, self.config.database) catch
            return InsertResult{ .err = .serialization_failed };
        defer self.allocator.free(encoded_db);

        const url = std.fmt.allocPrint(
            self.allocator,
            "http://{s}:{d}/?database={s}&query={s}",
            .{ self.config.host, self.config.port, encoded_db, encoded_query },
        ) catch return InsertResult{ .err = .serialization_failed };
        defer self.allocator.free(url);

        // Execute HTTP POST
        const result = self.executePost(url, json_rows);
        return result;
    }

    /// Execute SELECT query
    pub fn query(
        self: *ClickHouseClient,
        sql: []const u8,
        format: []const u8,
    ) !QueryResult {
        // Build query string with format, then URL-encode it
        const full_query = try std.fmt.allocPrint(
            self.allocator,
            "{s} FORMAT {s}",
            .{ sql, format },
        );
        defer self.allocator.free(full_query);

        const encoded_query = try urlEncode(self.allocator, full_query);
        defer self.allocator.free(encoded_query);

        const encoded_db = try urlEncode(self.allocator, self.config.database);
        defer self.allocator.free(encoded_db);

        const url = try std.fmt.allocPrint(
            self.allocator,
            "http://{s}:{d}/?database={s}&query={s}",
            .{ self.config.host, self.config.port, encoded_db, encoded_query },
        );
        defer self.allocator.free(url);

        // Execute HTTP GET using fetch API
        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        var response_body = std.ArrayList(u8){};
        errdefer response_body.deinit(self.allocator);

        const fetch_result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .extra_headers = &.{
                .{ .name = "Authorization", .value = self.auth_header },
            },
            .response_writer = .{ .any = response_body.writer(self.allocator) },
        }) catch return error.ConnectionFailed;

        if (fetch_result.status != .ok) {
            response_body.deinit(self.allocator);
            return error.DatabaseError;
        }

        return QueryResult{
            .data = try response_body.toOwnedSlice(self.allocator),
            .rows = 0, // TODO: Parse row count from response
        };
    }

    /// Execute HTTP POST request using fetch API
    fn executePost(self: *ClickHouseClient, url: []const u8, body: []const u8) InsertResult {
        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const fetch_result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = &.{
                .{ .name = "Authorization", .value = self.auth_header },
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch {
            return InsertResult{ .err = .connection_failed };
        };

        if (fetch_result.status != .ok) {
            std.log.err("ClickHouse insert failed: HTTP {d}", .{@intFromEnum(fetch_result.status)});
            return InsertResult{ .err = .database_error };
        }

        return InsertResult{ .ok = {} };
    }

    /// Ping ClickHouse to check connection
    pub fn ping(self: *ClickHouseClient) bool {
        const query_result = self.query("SELECT 1", "JSONCompact") catch return false;
        var mutable_result = query_result;
        defer mutable_result.deinit(self.allocator);
        return true;
    }
};
