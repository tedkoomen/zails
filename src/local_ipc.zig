/// Machine-local Zails request transport.
///
/// A Zails server publishes a small registrar record under /tmp/zails/ports
/// that points to a memory-mapped request ring. Loopback clients can use this
/// transport opportunistically and fall back to TCP whenever the registrar or
/// ring is unavailable.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const REGISTRY_ROOT = "/tmp/zails";
pub const PORTS_DIR = "/tmp/zails/ports";
pub const SHM_DIR = "/tmp/zails/shm";

pub const VERSION: u32 = 1;
pub const SLOT_COUNT: usize = 64;
pub const SLOT_PAYLOAD_BYTES: usize = 8192;
pub const DEFAULT_TIMEOUT_US: u64 = 2_000_000;

const RING_MAGIC: u64 = 0x5a41_494c_5352_4e47; // "ZAILSRNG"

const STATE_EMPTY: u32 = 0;
const STATE_WRITING: u32 = 1;
const STATE_REQUEST_READY: u32 = 2;
const STATE_PROCESSING: u32 = 3;
const STATE_RESPONSE_READY: u32 = 4;
const STATE_FAILED: u32 = 5;
const STATE_ABANDONED: u32 = 6;

const RingHeader = extern struct {
    magic: u64 = RING_MAGIC,
    version: u32 = VERSION,
    slot_count: u32 = SLOT_COUNT,
    slot_payload_bytes: u32 = SLOT_PAYLOAD_BYTES,
    port: u32 = 0,
    server_pid: u32 = 0,
    server_id_hi: u64 = 0,
    server_id_lo: u64 = 0,
    client_cursor: u64 = 0,
    ready: u32 = 0,
    shutdown: u32 = 0,
    reserved: [32]u8 = [_]u8{0} ** 32,
};

const Slot = extern struct {
    state: u32 = STATE_EMPTY,
    msg_type: u8 = 0,
    flags: u8 = 0,
    error_code: u16 = 0,
    request_len: u32 = 0,
    response_len: u32 = 0,
    request_id: u64 = 0,
    client_pid: u32 = 0,
    reserved: u32 = 0,
    request_data: [SLOT_PAYLOAD_BYTES]u8 = [_]u8{0} ** SLOT_PAYLOAD_BYTES,
    response_data: [SLOT_PAYLOAD_BYTES]u8 = [_]u8{0} ** SLOT_PAYLOAD_BYTES,
};

const SharedRing = extern struct {
    header: RingHeader = .{},
    slots: [SLOT_COUNT]Slot = [_]Slot{.{}} ** SLOT_COUNT,
};

const RegistrarEntry = struct {
    port: u16,
    pid: u32,
    version: u32,
    slot_count: usize,
    slot_payload_bytes: usize,
    server_id_hi: u64,
    server_id_lo: u64,
    shm_path: []const u8,

    fn serverId(self: RegistrarEntry) u128 {
        return (@as(u128, self.server_id_hi) << 64) | @as(u128, self.server_id_lo);
    }
};

pub const ClientStats = struct {
    used_local_ipc: bool = false,
    fallback_reason: []const u8 = "",
};

const CachedRing = struct {
    port: u16,
    server_id: u128,
    mapped: []align(std.heap.page_size_min) u8,
    ring: *SharedRing,
};

const ClientCache = struct {
    threadlocal var ring: ?CachedRing = null;
};

pub fn isLoopbackHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1");
}

pub fn tryRequest(
    allocator: Allocator,
    host: []const u8,
    port: u16,
    msg_type: u8,
    request_data: []const u8,
    response_buffer: []u8,
    timeout_us: u64,
    stats: ?*ClientStats,
) !?[]const u8 {
    if (stats) |s| s.* = .{};
    if (!isLoopbackHost(host)) {
        if (stats) |s| s.fallback_reason = "target is not loopback";
        return null;
    }
    if (request_data.len > SLOT_PAYLOAD_BYTES or response_buffer.len == 0) {
        if (stats) |s| s.fallback_reason = "payload too large or response buffer empty for local ipc slot";
        return null;
    }

    if (getCachedRing(port)) |ring| {
        const response = try requestViaRing(ring, msg_type, request_data, response_buffer, timeout_us);
        if (response) |data| {
            if (stats) |s| {
                s.used_local_ipc = true;
                s.fallback_reason = "";
            }
            return data;
        }
        clearCachedRing();
        if (stats) |s| s.fallback_reason = "cached local ipc request failed";
        return null;
    }

    const entry = readRegistrarEntry(allocator, port) catch {
        if (stats) |s| s.fallback_reason = "registrar entry unavailable";
        return null;
    };
    defer allocator.free(entry.shm_path);

    const file = std.fs.openFileAbsolute(entry.shm_path, .{ .mode = .read_write }) catch {
        if (stats) |s| s.fallback_reason = "ring file unavailable";
        return null;
    };
    defer file.close();

    const mapped = std.posix.mmap(
        null,
        @sizeOf(SharedRing),
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        file.handle,
        0,
    ) catch {
        if (stats) |s| s.fallback_reason = "ring mmap failed";
        return null;
    };
    const ring: *SharedRing = @ptrCast(@alignCast(mapped.ptr));
    if (!validateRing(ring, entry)) {
        std.posix.munmap(mapped);
        if (stats) |s| s.fallback_reason = "ring validation failed";
        return null;
    }

    cacheRing(port, entry.serverId(), mapped);

    const response = try requestViaRing(ring, msg_type, request_data, response_buffer, timeout_us);
    if (response == null) {
        clearCachedRing();
    }
    if (stats) |s| {
        s.used_local_ipc = response != null;
        s.fallback_reason = if (response == null) "local ipc request failed" else "";
    }
    return response;
}

pub fn LocalIpcServer(comptime RegistryType: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        port: u16,
        server_id: u128,
        registry: *RegistryType,
        ring_file: std.fs.File,
        mapped: []align(std.heap.page_size_min) u8,
        ring: *SharedRing,
        ring_path: []u8,
        registrar_path: []u8,
        arena: std.heap.ArenaAllocator,
        shutdown: std.atomic.Value(bool),
        thread: ?std.Thread,

        pub fn init(allocator: Allocator, port: u16, registry: *RegistryType) !Self {
            try ensureRegistrarDirs();

            const server_id = generateServerId();
            const ring_path = try buildRingPath(allocator, port, server_id);
            errdefer allocator.free(ring_path);

            const registrar_path = try buildRegistrarPath(allocator, port);
            errdefer allocator.free(registrar_path);

            const ring_file = try std.fs.createFileAbsolute(ring_path, .{
                .read = true,
                .truncate = true,
                .mode = 0o600,
            });
            errdefer ring_file.close();

            try ring_file.setEndPos(@sizeOf(SharedRing));

            const mapped = try std.posix.mmap(
                null,
                @sizeOf(SharedRing),
                std.posix.PROT.READ | std.posix.PROT.WRITE,
                .{ .TYPE = .SHARED },
                ring_file.handle,
                0,
            );
            errdefer std.posix.munmap(mapped);

            const ring: *SharedRing = @ptrCast(@alignCast(mapped.ptr));
            initializeRing(ring, port, server_id);
            try publishRegistrar(registrar_path, port, server_id, ring_path);

            return Self{
                .allocator = allocator,
                .port = port,
                .server_id = server_id,
                .registry = registry,
                .ring_file = ring_file,
                .mapped = mapped,
                .ring = ring,
                .ring_path = ring_path,
                .registrar_path = registrar_path,
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .shutdown = std.atomic.Value(bool).init(false),
                .thread = null,
            };
        }

        pub fn start(self: *Self) !void {
            if (self.thread != null) return;
            self.thread = try std.Thread.spawn(.{}, Self.run, .{self});
        }

        pub fn deinit(self: *Self) void {
            self.shutdown.store(true, .release);
            @atomicStore(u32, &self.ring.header.shutdown, 1, .release);

            if (self.thread) |thread| {
                thread.join();
                self.thread = null;
            }

            @atomicStore(u32, &self.ring.header.ready, 0, .release);
            std.fs.deleteFileAbsolute(self.registrar_path) catch {};
            std.posix.munmap(self.mapped);
            self.ring_file.close();
            std.fs.deleteFileAbsolute(self.ring_path) catch {};
            self.arena.deinit();
            self.allocator.free(self.registrar_path);
            self.allocator.free(self.ring_path);
        }

        fn run(self: *Self) void {
            std.log.info("Local IPC registrar published for port {} at {s}", .{
                self.port,
                self.registrar_path,
            });

            while (!self.shutdown.load(.acquire) and
                @atomicLoad(u32, &self.ring.header.shutdown, .acquire) == 0)
            {
                if (processReadySlots(RegistryType, self.ring, self.registry, &self.arena) == 0) {
                    std.atomic.spinLoopHint();
                    std.Thread.yield() catch {};
                }
            }
        }
    };
}

fn processReadySlots(
    comptime RegistryType: type,
    ring: *SharedRing,
    registry: *RegistryType,
    arena: *std.heap.ArenaAllocator,
) usize {
    var processed: usize = 0;
    for (&ring.slots) |*slot| {
        if (@cmpxchgStrong(
            u32,
            &slot.state,
            STATE_REQUEST_READY,
            STATE_PROCESSING,
            .acquire,
            .monotonic,
        ) == null) {
            processSlotWithRegistry(RegistryType, registry, slot, arena);
            processed += 1;
        }
    }
    return processed;
}

fn responseStartsAtSlot(slot: *const Slot, data: []const u8) bool {
    return @intFromPtr(data.ptr) == @intFromPtr(&slot.response_data);
}

fn finishSlot(slot: *Slot, final_state: u32) void {
    if (@cmpxchgStrong(
        u32,
        &slot.state,
        STATE_PROCESSING,
        final_state,
        .release,
        .acquire,
    )) |state| {
        if (state == STATE_ABANDONED) {
            slot.response_len = 0;
            slot.error_code = 0;
            @atomicStore(u32, &slot.state, STATE_EMPTY, .release);
        }
    }
}

fn processSlotWithRegistry(
    comptime RegistryType: type,
    registry: *RegistryType,
    slot: *Slot,
    arena: *std.heap.ArenaAllocator,
) void {
    defer _ = arena.reset(.retain_capacity);

    const request_len = @min(slot.request_len, SLOT_PAYLOAD_BYTES);
    const request_data = slot.request_data[0..request_len];

    const handler_response = registry.handle(
        slot.msg_type,
        request_data,
        &slot.response_data,
        arena.allocator(),
    );

    if (handler_response.isOk()) {
        const response_len = @min(handler_response.data.len, SLOT_PAYLOAD_BYTES);
        slot.response_len = @intCast(response_len);
        if (!responseStartsAtSlot(slot, handler_response.data)) {
            @memcpy(slot.response_data[0..response_len], handler_response.data[0..response_len]);
        }
        slot.error_code = 0;
        finishSlot(slot, STATE_RESPONSE_READY);
    } else {
        slot.response_len = 0;
        slot.error_code = @intCast(@intFromEnum(handler_response.error_code));
        finishSlot(slot, STATE_FAILED);
    }
}

fn ensureRegistrarDirs() !void {
    std.fs.makeDirAbsolute(REGISTRY_ROOT) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    std.fs.makeDirAbsolute(PORTS_DIR) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    std.fs.makeDirAbsolute(SHM_DIR) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

fn initializeRing(ring: *SharedRing, port: u16, server_id: u128) void {
    ring.* = .{};
    ring.header = .{
        .magic = RING_MAGIC,
        .version = VERSION,
        .slot_count = SLOT_COUNT,
        .slot_payload_bytes = SLOT_PAYLOAD_BYTES,
        .port = port,
        .server_pid = currentPid(),
        .server_id_hi = @intCast(server_id >> 64),
        .server_id_lo = @truncate(server_id),
        .client_cursor = 0,
        .ready = 1,
        .shutdown = 0,
        .reserved = [_]u8{0} ** 32,
    };
}

fn validateRing(ring: *SharedRing, entry: RegistrarEntry) bool {
    return ring.header.magic == RING_MAGIC and
        ring.header.version == VERSION and
        ring.header.slot_count == SLOT_COUNT and
        ring.header.slot_payload_bytes == SLOT_PAYLOAD_BYTES and
        ring.header.port == entry.port and
        ring.header.server_id_hi == entry.server_id_hi and
        ring.header.server_id_lo == entry.server_id_lo and
        @atomicLoad(u32, &ring.header.ready, .acquire) == 1 and
        @atomicLoad(u32, &ring.header.shutdown, .acquire) == 0;
}

fn validateCachedRing(ring: *SharedRing, port: u16, server_id: u128) bool {
    return ring.header.magic == RING_MAGIC and
        ring.header.version == VERSION and
        ring.header.slot_count == SLOT_COUNT and
        ring.header.slot_payload_bytes == SLOT_PAYLOAD_BYTES and
        ring.header.port == port and
        ring.header.server_id_hi == @as(u64, @intCast(server_id >> 64)) and
        ring.header.server_id_lo == @as(u64, @truncate(server_id)) and
        @atomicLoad(u32, &ring.header.ready, .acquire) == 1 and
        @atomicLoad(u32, &ring.header.shutdown, .acquire) == 0;
}

fn getCachedRing(port: u16) ?*SharedRing {
    if (ClientCache.ring) |cached| {
        if (cached.port == port and validateCachedRing(cached.ring, cached.port, cached.server_id)) {
            return cached.ring;
        }
        clearCachedRing();
    }
    return null;
}

fn cacheRing(port: u16, server_id: u128, mapped: []align(std.heap.page_size_min) u8) void {
    clearCachedRing();
    ClientCache.ring = .{
        .port = port,
        .server_id = server_id,
        .mapped = mapped,
        .ring = @ptrCast(@alignCast(mapped.ptr)),
    };
}

fn clearCachedRing() void {
    if (ClientCache.ring) |cached| {
        std.posix.munmap(cached.mapped);
        ClientCache.ring = null;
    }
}

fn requestViaRing(
    ring: *SharedRing,
    msg_type: u8,
    request_data: []const u8,
    response_buffer: []u8,
    timeout_us: u64,
) !?[]const u8 {
    const timeout_ns: i128 = @as(i128, @intCast(if (timeout_us == 0) DEFAULT_TIMEOUT_US else timeout_us)) * std.time.ns_per_us;
    const deadline = std.time.nanoTimestamp() + timeout_ns;

    const slot = reserveSlot(ring) orelse return null;
    const request_id = slot.request_id;

    slot.msg_type = msg_type;
    slot.flags = 0;
    slot.error_code = 0;
    slot.request_len = @intCast(request_data.len);
    slot.response_len = 0;
    slot.request_id = request_id;
    slot.client_pid = currentPid();
    @memcpy(slot.request_data[0..request_data.len], request_data);

    @atomicStore(u32, &slot.state, STATE_REQUEST_READY, .release);

    var spins: usize = 0;
    while (std.time.nanoTimestamp() < deadline) {
        const state = @atomicLoad(u32, &slot.state, .acquire);
        if (state == STATE_RESPONSE_READY) {
            const response_len = @min(slot.response_len, @as(u32, @intCast(response_buffer.len)));
            @memcpy(response_buffer[0..response_len], slot.response_data[0..response_len]);
            @atomicStore(u32, &slot.state, STATE_EMPTY, .release);
            return response_buffer[0..response_len];
        }
        if (state == STATE_FAILED) {
            @atomicStore(u32, &slot.state, STATE_EMPTY, .release);
            return null;
        }

        if (spins < 512) {
            spins += 1;
            std.atomic.spinLoopHint();
        } else {
            std.Thread.yield() catch {};
        }
    }

    while (true) {
        const state = @atomicLoad(u32, &slot.state, .acquire);
        switch (state) {
            STATE_RESPONSE_READY => {
                const response_len = @min(slot.response_len, @as(u32, @intCast(response_buffer.len)));
                @memcpy(response_buffer[0..response_len], slot.response_data[0..response_len]);
                @atomicStore(u32, &slot.state, STATE_EMPTY, .release);
                return response_buffer[0..response_len];
            },
            STATE_FAILED => {
                @atomicStore(u32, &slot.state, STATE_EMPTY, .release);
                return null;
            },
            STATE_REQUEST_READY => {
                if (@cmpxchgStrong(u32, &slot.state, STATE_REQUEST_READY, STATE_EMPTY, .acquire, .monotonic) == null) {
                    return null;
                }
            },
            STATE_PROCESSING => {
                if (@cmpxchgStrong(u32, &slot.state, STATE_PROCESSING, STATE_ABANDONED, .acq_rel, .monotonic) == null) {
                    return null;
                }
            },
            else => return null,
        }
    }
}

fn reserveSlot(ring: *SharedRing) ?*Slot {
    const start = @atomicRmw(u64, &ring.header.client_cursor, .Add, 1, .monotonic);
    for (0..SLOT_COUNT) |probe| {
        const index = (start + probe) % SLOT_COUNT;
        const slot = &ring.slots[index];
        if (@cmpxchgStrong(
            u32,
            &slot.state,
            STATE_EMPTY,
            STATE_WRITING,
            .acquire,
            .monotonic,
        ) == null) {
            slot.request_id = start;
            return slot;
        }
    }
    return null;
}

fn publishRegistrar(path: []const u8, port: u16, server_id: u128, ring_path: []const u8) !void {
    var file = try std.fs.createFileAbsolute(path, .{
        .read = true,
        .truncate = true,
        .mode = 0o600,
    });
    defer file.close();

    var buffer: [1024]u8 = undefined;
    const contents = try std.fmt.bufPrint(
        &buffer,
        "version={d}\nport={d}\npid={d}\nserver_id_hi={d}\nserver_id_lo={d}\nslot_count={d}\nslot_payload_bytes={d}\nshm_path={s}\n",
        .{
            VERSION,
            port,
            currentPid(),
            @as(u64, @intCast(server_id >> 64)),
            @as(u64, @truncate(server_id)),
            SLOT_COUNT,
            SLOT_PAYLOAD_BYTES,
            ring_path,
        },
    );
    try file.writeAll(contents);
}

fn readRegistrarEntry(allocator: Allocator, port: u16) !RegistrarEntry {
    const path = try buildRegistrarPath(allocator, port);
    defer allocator.free(path);

    const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(contents);

    var entry = RegistrarEntry{
        .port = port,
        .pid = 0,
        .version = 0,
        .slot_count = 0,
        .slot_payload_bytes = 0,
        .server_id_hi = 0,
        .server_id_lo = 0,
        .shm_path = "",
    };

    var shm_path: ?[]u8 = null;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const eql = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eql];
        const value = line[eql + 1 ..];
        if (std.mem.eql(u8, key, "version")) {
            entry.version = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "port")) {
            entry.port = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, key, "pid")) {
            entry.pid = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "server_id_hi")) {
            entry.server_id_hi = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, key, "server_id_lo")) {
            entry.server_id_lo = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, key, "slot_count")) {
            entry.slot_count = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, key, "slot_payload_bytes")) {
            entry.slot_payload_bytes = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, key, "shm_path")) {
            shm_path = try allocator.dupe(u8, value);
        }
    }

    entry.shm_path = shm_path orelse return error.InvalidRegistrarEntry;
    if (entry.version != VERSION or
        entry.port != port or
        entry.slot_count != SLOT_COUNT or
        entry.slot_payload_bytes != SLOT_PAYLOAD_BYTES or
        entry.serverId() == 0)
    {
        allocator.free(entry.shm_path);
        return error.InvalidRegistrarEntry;
    }

    return entry;
}

fn buildRegistrarPath(allocator: Allocator, port: u16) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{d}.meta", .{ PORTS_DIR, port });
}

fn buildRingPath(allocator: Allocator, port: u16, server_id: u128) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{d}-{x}.ring", .{ SHM_DIR, port, server_id });
}

fn generateServerId() u128 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return std.mem.readInt(u128, &bytes, .big);
}

fn currentPid() u32 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        .macos, .ios, .tvos, .watchos, .visionos => @intCast(std.c.getpid()),
        else => 0,
    };
}

fn skipUnlessLinux() !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
}

const TestError = enum(u8) { none = 0, handler_failed = 31 };

const TestResponse = struct {
    data: []const u8,
    error_code: TestError,

    fn ok(data: []const u8) TestResponse {
        return .{ .data = data, .error_code = .none };
    }

    fn err(error_code: TestError) TestResponse {
        return .{ .data = "", .error_code = error_code };
    }

    fn isOk(self: TestResponse) bool {
        return self.error_code == .none;
    }
};

test "loopback host detection" {
    try skipUnlessLinux();

    try std.testing.expect(isLoopbackHost("localhost"));
    try std.testing.expect(isLoopbackHost("127.0.0.1"));
    try std.testing.expect(isLoopbackHost("::1"));
    try std.testing.expect(!isLoopbackHost("example.com"));
}

test "shared ring has expected dimensions" {
    try skipUnlessLinux();

    const ring = SharedRing{};
    try std.testing.expectEqual(@as(usize, SLOT_COUNT), ring.slots.len);
    try std.testing.expect(@sizeOf(SharedRing) > SLOT_COUNT * SLOT_PAYLOAD_BYTES);
}

test "simulation processes ready slot and returns response" {
    try skipUnlessLinux();

    const MockError = enum(u8) { none = 0, handler_failed = 31 };
    const MockResponse = struct {
        data: []const u8,
        error_code: MockError,

        fn ok(data: []const u8) @This() {
            return .{ .data = data, .error_code = .none };
        }

        fn isOk(self: @This()) bool {
            return self.error_code == .none;
        }
    };
    const MockRegistry = struct {
        handled: u32 = 0,
        last_msg_type: u8 = 0,

        fn handle(
            self: *@This(),
            msg_type: u8,
            request_data: []const u8,
            response_buffer: []u8,
            allocator: Allocator,
        ) MockResponse {
            _ = allocator;
            self.handled += 1;
            self.last_msg_type = msg_type;
            @memcpy(response_buffer[0..request_data.len], request_data);
            return MockResponse.ok(response_buffer[0..request_data.len]);
        }
    };

    var ring = SharedRing{};
    var registry = MockRegistry{};
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    initializeRing(&ring, 39184, 0x1234);

    const slot = reserveSlot(&ring) orelse return error.NoSlotReserved;
    const payload = "hello-sim";
    slot.msg_type = 7;
    slot.error_code = 0;
    slot.request_len = payload.len;
    slot.response_len = 0;
    slot.request_id = 1;
    slot.client_pid = currentPid();
    @memcpy(slot.request_data[0..payload.len], payload);
    @atomicStore(u32, &slot.state, STATE_REQUEST_READY, .release);

    try std.testing.expectEqual(
        @as(usize, 1),
        processReadySlots(MockRegistry, &ring, &registry, &arena),
    );
    try std.testing.expectEqual(@as(u32, 1), registry.handled);
    try std.testing.expectEqual(@as(u8, 7), registry.last_msg_type);
    try std.testing.expectEqual(
        STATE_RESPONSE_READY,
        @atomicLoad(u32, &slot.state, .acquire),
    );
    try std.testing.expectEqual(@as(u32, payload.len), slot.response_len);
    try std.testing.expectEqualStrings(
        payload,
        slot.response_data[0..@as(usize, @intCast(slot.response_len))],
    );
}

test "simulation marks failed slot when registry returns error" {
    try skipUnlessLinux();

    const MockError = enum(u8) { none = 0, handler_failed = 31 };
    const MockResponse = struct {
        data: []const u8,
        error_code: MockError,

        fn err(error_code: MockError) @This() {
            return .{ .data = "", .error_code = error_code };
        }

        fn isOk(self: @This()) bool {
            return self.error_code == .none;
        }
    };
    const MockRegistry = struct {
        fn handle(
            self: *@This(),
            msg_type: u8,
            request_data: []const u8,
            response_buffer: []u8,
            allocator: Allocator,
        ) MockResponse {
            _ = self;
            _ = msg_type;
            _ = request_data;
            _ = response_buffer;
            _ = allocator;
            return MockResponse.err(.handler_failed);
        }
    };

    var ring = SharedRing{};
    var registry = MockRegistry{};
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    initializeRing(&ring, 39185, 0x5678);

    const slot = reserveSlot(&ring) orelse return error.NoSlotReserved;
    slot.msg_type = 9;
    slot.request_len = 0;
    slot.response_len = 123;
    @atomicStore(u32, &slot.state, STATE_REQUEST_READY, .release);

    try std.testing.expectEqual(
        @as(usize, 1),
        processReadySlots(MockRegistry, &ring, &registry, &arena),
    );
    try std.testing.expectEqual(
        STATE_FAILED,
        @atomicLoad(u32, &slot.state, .acquire),
    );
    try std.testing.expectEqual(@as(u32, 0), slot.response_len);
    try std.testing.expectEqual(@as(u16, 31), slot.error_code);
}

test "simulation reports no available slot when ring is full" {
    try skipUnlessLinux();

    var ring = SharedRing{};
    initializeRing(&ring, 39186, 0x9abc);

    for (&ring.slots) |*slot| {
        @atomicStore(u32, &slot.state, STATE_WRITING, .release);
    }

    try std.testing.expect(reserveSlot(&ring) == null);
}

test "simulation validates registrar metadata against ring header" {
    try skipUnlessLinux();

    const server_id: u128 = 0x1122_3344_5566_7788_99aa_bbcc_ddee_ff00;
    var ring = SharedRing{};
    initializeRing(&ring, 39187, server_id);

    var entry = RegistrarEntry{
        .port = 39187,
        .pid = currentPid(),
        .version = VERSION,
        .slot_count = SLOT_COUNT,
        .slot_payload_bytes = SLOT_PAYLOAD_BYTES,
        .server_id_hi = @intCast(server_id >> 64),
        .server_id_lo = @truncate(server_id),
        .shm_path = "/tmp/zails/shm/sim.ring",
    };

    try std.testing.expect(validateRing(&ring, entry));

    entry.server_id_lo ^= 1;
    try std.testing.expect(!validateRing(&ring, entry));

    entry.server_id_lo = @truncate(server_id);
    @atomicStore(u32, &ring.header.ready, 0, .release);
    try std.testing.expect(!validateRing(&ring, entry));
}

test "tryRequest fallback decisions avoid filesystem access" {
    try skipUnlessLinux();

    const allocator = std.testing.allocator;
    var response_buffer: [SLOT_PAYLOAD_BYTES]u8 = undefined;
    var stats = ClientStats{};

    const non_loopback = try tryRequest(
        allocator,
        "example.com",
        39188,
        1,
        "hello",
        &response_buffer,
        1,
        &stats,
    );
    try std.testing.expect(non_loopback == null);
    try std.testing.expect(!stats.used_local_ipc);
    try std.testing.expectEqualStrings("target is not loopback", stats.fallback_reason);

    var oversized_request: [SLOT_PAYLOAD_BYTES + 1]u8 = undefined;
    const oversized = try tryRequest(
        allocator,
        "localhost",
        39188,
        1,
        &oversized_request,
        &response_buffer,
        1,
        &stats,
    );
    try std.testing.expect(oversized == null);
    try std.testing.expect(!stats.used_local_ipc);
    try std.testing.expectEqualStrings(
        "payload too large or response buffer empty for local ipc slot",
        stats.fallback_reason,
    );
}

test "local ipc round trip with mock registry" {
    try skipUnlessLinux();

    const MockError = enum(u8) { none = 0, handler_failed = 31 };
    const MockResponse = struct {
        data: []const u8,
        error_code: MockError,

        fn ok(data: []const u8) @This() {
            return .{ .data = data, .error_code = .none };
        }

        fn isOk(self: @This()) bool {
            return self.error_code == .none;
        }
    };
    const MockRegistry = struct {
        fn handle(
            self: *@This(),
            msg_type: u8,
            request_data: []const u8,
            response_buffer: []u8,
            allocator: Allocator,
        ) MockResponse {
            _ = self;
            _ = msg_type;
            _ = allocator;
            @memcpy(response_buffer[0..request_data.len], request_data);
            return MockResponse.ok(response_buffer[0..request_data.len]);
        }
    };

    const allocator = std.testing.allocator;
    var registry = MockRegistry{};
    const Server = LocalIpcServer(MockRegistry);
    var server = try Server.init(allocator, 39183, &registry);
    defer server.deinit();
    try server.start();

    var response_buffer: [SLOT_PAYLOAD_BYTES]u8 = undefined;
    const response = (try tryRequest(
        allocator,
        "localhost",
        39183,
        1,
        "hello-shm",
        &response_buffer,
        DEFAULT_TIMEOUT_US,
        null,
    )) orelse return error.NoLocalIpcResponse;

    try std.testing.expectEqualStrings("hello-shm", response);
}

test "local ipc handles concurrent clients on one ring" {
    try skipUnlessLinux();
    clearCachedRing();
    defer clearCachedRing();

    const port: u16 = 39195;
    const client_count = 8;
    const requests_per_client = 100;

    const MockRegistry = struct {
        handled: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        fn handle(
            self: *@This(),
            msg_type: u8,
            request_data: []const u8,
            response_buffer: []u8,
            allocator: Allocator,
        ) TestResponse {
            _ = msg_type;
            _ = allocator;
            _ = self.handled.fetchAdd(1, .monotonic);
            @memcpy(response_buffer[0..request_data.len], request_data);
            return TestResponse.ok(response_buffer[0..request_data.len]);
        }
    };

    const ClientContext = struct {
        port: u16,
        client_id: usize,
        failures: *std.atomic.Value(usize),
    };

    const Client = struct {
        fn run(ctx: ClientContext) void {
            var response_buffer: [SLOT_PAYLOAD_BYTES]u8 = undefined;
            var request_buffer: [64]u8 = undefined;

            for (0..requests_per_client) |i| {
                const request = std.fmt.bufPrint(
                    &request_buffer,
                    "client-{d}-request-{d}",
                    .{ ctx.client_id, i },
                ) catch {
                    _ = ctx.failures.fetchAdd(1, .monotonic);
                    continue;
                };

                const response = tryRequest(
                    std.heap.page_allocator,
                    "localhost",
                    ctx.port,
                    1,
                    request,
                    &response_buffer,
                    500_000,
                    null,
                ) catch {
                    _ = ctx.failures.fetchAdd(1, .monotonic);
                    continue;
                };

                const payload = response orelse {
                    _ = ctx.failures.fetchAdd(1, .monotonic);
                    continue;
                };

                if (!std.mem.eql(u8, request, payload)) {
                    _ = ctx.failures.fetchAdd(1, .monotonic);
                }
            }
        }
    };

    const allocator = std.testing.allocator;
    var registry = MockRegistry{};
    const Server = LocalIpcServer(MockRegistry);
    var server = try Server.init(allocator, port, &registry);
    defer server.deinit();
    try server.start();

    var failures = std.atomic.Value(usize).init(0);
    var threads: [client_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, client_id| {
        thread.* = try std.Thread.spawn(.{}, Client.run, .{ClientContext{
            .port = port,
            .client_id = client_id,
            .failures = &failures,
        }});
    }

    for (threads) |thread| {
        thread.join();
    }

    try std.testing.expectEqual(@as(usize, 0), failures.load(.acquire));
    try std.testing.expectEqual(
        @as(u64, client_count * requests_per_client),
        registry.handled.load(.acquire),
    );
}

test "local ipc timeout while processing abandons and recycles slot" {
    try skipUnlessLinux();

    const SlowRegistry = struct {
        entered: *std.atomic.Value(bool),

        fn handle(
            self: *@This(),
            msg_type: u8,
            request_data: []const u8,
            response_buffer: []u8,
            allocator: Allocator,
        ) TestResponse {
            _ = msg_type;
            _ = allocator;
            self.entered.store(true, .release);
            std.Thread.sleep(50 * std.time.ns_per_ms);
            @memcpy(response_buffer[0..request_data.len], request_data);
            return TestResponse.ok(response_buffer[0..request_data.len]);
        }
    };

    const ServerContext = struct {
        ring: *SharedRing,
        registry: *SlowRegistry,
        arena: *std.heap.ArenaAllocator,
        processed: *std.atomic.Value(bool),
    };

    const ServerWorker = struct {
        fn run(ctx: ServerContext) void {
            while (!ctx.processed.load(.acquire)) {
                if (processReadySlots(SlowRegistry, ctx.ring, ctx.registry, ctx.arena) > 0) {
                    ctx.processed.store(true, .release);
                    return;
                }
                std.atomic.spinLoopHint();
            }
        }
    };

    const ClientContext = struct {
        ring: *SharedRing,
        timed_out: *std.atomic.Value(bool),
        completed: *std.atomic.Value(bool),
    };

    const ClientWorker = struct {
        fn run(ctx: ClientContext) void {
            var response_buffer: [SLOT_PAYLOAD_BYTES]u8 = undefined;
            const response = requestViaRing(ctx.ring, 1, "slow", &response_buffer, 20_000) catch null;
            ctx.timed_out.store(response == null, .release);
            ctx.completed.store(true, .release);
        }
    };

    var ring = SharedRing{};
    initializeRing(&ring, 39196, 0xfeed_beef);
    var entered = std.atomic.Value(bool).init(false);
    var registry = SlowRegistry{ .entered = &entered };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var processed = std.atomic.Value(bool).init(false);
    var timed_out = std.atomic.Value(bool).init(false);
    var completed = std.atomic.Value(bool).init(false);

    const client_thread = try std.Thread.spawn(.{}, ClientWorker.run, .{ClientContext{
        .ring = &ring,
        .timed_out = &timed_out,
        .completed = &completed,
    }});
    const server_thread = try std.Thread.spawn(.{}, ServerWorker.run, .{ServerContext{
        .ring = &ring,
        .registry = &registry,
        .arena = &arena,
        .processed = &processed,
    }});

    var waited_ns: u64 = 0;
    while (!entered.load(.acquire) and waited_ns < 500 * std.time.ns_per_ms) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
        waited_ns += 1 * std.time.ns_per_ms;
    }

    try std.testing.expect(entered.load(.acquire));
    client_thread.join();
    server_thread.join();

    try std.testing.expect(completed.load(.acquire));
    try std.testing.expect(timed_out.load(.acquire));
    try std.testing.expect(processed.load(.acquire));
    for (&ring.slots) |*slot| {
        try std.testing.expectEqual(STATE_EMPTY, @atomicLoad(u32, &slot.state, .acquire));
    }
}

test "local ipc clears stale cached ring after server restart" {
    try skipUnlessLinux();
    clearCachedRing();
    defer clearCachedRing();

    const port: u16 = 39197;
    const PrefixRegistry = struct {
        prefix: []const u8,

        fn handle(
            self: *@This(),
            msg_type: u8,
            request_data: []const u8,
            response_buffer: []u8,
            allocator: Allocator,
        ) TestResponse {
            _ = msg_type;
            _ = allocator;
            const total_len = self.prefix.len + request_data.len;
            if (total_len > response_buffer.len) return TestResponse.err(.handler_failed);
            @memcpy(response_buffer[0..self.prefix.len], self.prefix);
            @memcpy(response_buffer[self.prefix.len..total_len], request_data);
            return TestResponse.ok(response_buffer[0..total_len]);
        }
    };

    const allocator = std.testing.allocator;
    var response_buffer: [SLOT_PAYLOAD_BYTES]u8 = undefined;

    {
        var registry = PrefixRegistry{ .prefix = "one:" };
        const Server = LocalIpcServer(PrefixRegistry);
        var server = try Server.init(allocator, port, &registry);
        defer server.deinit();
        try server.start();

        const response = (try tryRequest(
            allocator,
            "localhost",
            port,
            1,
            "ping",
            &response_buffer,
            DEFAULT_TIMEOUT_US,
            null,
        )) orelse return error.NoLocalIpcResponse;
        try std.testing.expectEqualStrings("one:ping", response);
    }

    {
        var registry = PrefixRegistry{ .prefix = "two:" };
        const Server = LocalIpcServer(PrefixRegistry);
        var server = try Server.init(allocator, port, &registry);
        defer server.deinit();
        try server.start();

        const response = (try tryRequest(
            allocator,
            "localhost",
            port,
            1,
            "ping",
            &response_buffer,
            DEFAULT_TIMEOUT_US,
            null,
        )) orelse return error.NoLocalIpcResponse;
        try std.testing.expectEqualStrings("two:ping", response);
    }
}
