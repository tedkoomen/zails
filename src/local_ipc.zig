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
    if (request_data.len > SLOT_PAYLOAD_BYTES or response_buffer.len < SLOT_PAYLOAD_BYTES) {
        if (stats) |s| s.fallback_reason = "payload or response buffer too large for local ipc slot";
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
    defer std.posix.munmap(mapped);

    const ring: *SharedRing = @ptrCast(@alignCast(mapped.ptr));
    if (!validateRing(ring, entry)) {
        if (stats) |s| s.fallback_reason = "ring validation failed";
        return null;
    }

    const response = try requestViaRing(ring, msg_type, request_data, response_buffer, timeout_us);
    if (stats) |s| {
        s.used_local_ipc = true;
        s.fallback_reason = "";
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
                if (processReadySlots(RegistryType, self.ring, self.registry) == 0) {
                    std.atomic.spinLoopHint();
                    std.Thread.yield() catch {};
                }
            }
        }
    };
}

fn processReadySlots(comptime RegistryType: type, ring: *SharedRing, registry: *RegistryType) usize {
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
            processSlotWithRegistry(RegistryType, registry, slot);
            processed += 1;
        }
    }
    return processed;
}

fn processSlotWithRegistry(comptime RegistryType: type, registry: *RegistryType, slot: *Slot) void {
    const request_len = @min(slot.request_len, SLOT_PAYLOAD_BYTES);
    const request_data = slot.request_data[0..request_len];

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const handler_response = registry.handle(
        slot.msg_type,
        request_data,
        &slot.response_data,
        arena.allocator(),
    );

    if (handler_response.isOk()) {
        slot.response_len = @intCast(@min(handler_response.data.len, SLOT_PAYLOAD_BYTES));
        slot.error_code = 0;
        @atomicStore(u32, &slot.state, STATE_RESPONSE_READY, .release);
    } else {
        slot.response_len = 0;
        slot.error_code = @intCast(@intFromEnum(handler_response.error_code));
        @atomicStore(u32, &slot.state, STATE_FAILED, .release);
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
    const request_id = @atomicRmw(u64, &ring.header.client_cursor, .Add, 1, .monotonic);

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

    _ = @cmpxchgStrong(u32, &slot.state, STATE_REQUEST_READY, STATE_EMPTY, .acquire, .monotonic);
    return null;
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
        processReadySlots(MockRegistry, &ring, &registry),
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
    initializeRing(&ring, 39185, 0x5678);

    const slot = reserveSlot(&ring) orelse return error.NoSlotReserved;
    slot.msg_type = 9;
    slot.request_len = 0;
    slot.response_len = 123;
    @atomicStore(u32, &slot.state, STATE_REQUEST_READY, .release);

    try std.testing.expectEqual(
        @as(usize, 1),
        processReadySlots(MockRegistry, &ring, &registry),
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
        "payload or response buffer too large for local ipc slot",
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
