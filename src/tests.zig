const std = @import("std");
const zigraft = @import("zigraft");

fn Named(comptime T: type) type {
    return struct {
        name: []const u8,

        getName: fn (T) []const u8 = struct {
            fn call(self: T) []const u8 {
                return self.name;
            }
        }.call,
    };
}

fn Reader(comptime T: type) type {
    return struct {
        read: fn (T, []u8) anyerror!usize,

        readAll: fn (T, []u8) anyerror!usize = struct {
            fn call(self: T, out: []u8) anyerror!usize {
                const impl = zigraft.Impl(Reader, T){};

                var idx: usize = 0;
                while (idx < out.len) {
                    const n = try impl.read(self, out[idx..]);
                    if (n == 0) break;
                    idx += n;
                }
                return idx;
            }
        }.call,
    };
}

pub fn NamedReader(comptime T: type) type {
    return zigraft.Compose(T, .{ Named, Reader }, struct {
        readWithLog: fn (T, []u8) anyerror!usize = struct {
            fn call(self: T, out: []u8) anyerror!usize {
                const impl = zigraft.Impl(NamedReader, T){};
                std.debug.print("reader={s}\n", .{self.name});
                return impl.read(self, out);
            }
        }.call,
    });
}

pub fn Seekable(comptime T: type) type {
    return struct {
        seekTo: fn (T, u64) anyerror!void,
    };
}

pub fn ReadSeek(comptime T: type) type {
    return zigraft.Compose(T, .{ Reader, Seekable }, struct {});
}

pub fn BufRead(comptime T: type) type {
    return zigraft.Compose(T, .{Reader}, struct {
        fillBuf: fn (T) anyerror![]const u8,
        consume: fn (T, usize) void,
    });
}

pub fn Stream(comptime T: type) type {
    return zigraft.Compose(T, .{ Named, ReadSeek, BufRead }, struct {
        describeAndRead: fn (T, []u8) anyerror!usize = struct {
            fn call(self: T, out: []u8) anyerror!usize {
                const impl = zigraft.Impl(Stream, T){};
                // std.debug.print("stream={s}\n", .{self.name});
                return impl.read(self, out);
            }
        }.call,
    });
}

const MyReader = struct {
    name: []const u8,
    buf: []const u8,
    pos: usize = 0,

    pub fn read(self: *MyReader, out: []u8) anyerror!usize {
        std.debug.print("reader 1\n", .{});
        if (self.pos >= self.buf.len) return 0;
        const remain = self.buf.len - self.pos;
        const n = @min(remain, out.len);
        @memcpy(out[0..n], self.buf[self.pos .. self.pos + n]);
        self.pos += n;
        return n;
    }

    pub fn seekTo(self: *MyReader, pos: u64) anyerror!void {
        if (pos > self.buf.len) return error.OutOfBounds;
        self.pos = @intCast(pos);
    }

    pub fn fillBuf(self: *MyReader) anyerror![]const u8 {
        return self.buf[self.pos..];
    }

    pub fn consume(self: *MyReader, n: usize) void {
        self.pos = @min(self.pos + n, self.buf.len);
    }
};

const MyReader2 = struct {
    name: []const u8,
    buf: []const u8,
    pos: usize = 0,

    const Self = @This();

    pub fn read(self: *Self, out: []u8) anyerror!usize {
        std.debug.print("reader 2\n", .{});
        if (self.pos >= self.buf.len) return 0;
        const remain = self.buf.len - self.pos;
        const n = @min(remain, out.len);
        @memcpy(out[0..n], self.buf[self.pos .. self.pos + n]);
        self.pos += n;
        return n;
    }

    pub fn seekTo(self: *Self, pos: u64) anyerror!void {
        if (pos > self.buf.len) return error.OutOfBounds;
        self.pos = @intCast(pos);
    }

    pub fn fillBuf(self: *Self) anyerror![]const u8 {
        return self.buf[self.pos..];
    }

    pub fn consume(self: *Self, n: usize) void {
        self.pos = @min(self.pos + n, self.buf.len);
    }
};

const ConstNamed = struct {
    name: []const u8,

    pub fn getName(self: *const ConstNamed) []const u8 {
        return self.name;
    }
};

const ValueNamed = struct {
    name: []const u8,

    pub fn getName(self: ValueNamed) []const u8 {
        return self.name;
    }
};

test "ordinary field constraint works" {
    zigraft.assertImpl(Named, *MyReader);
}

test "default method can use ordinary field" {
    var x = MyReader{ .name = "r1", .buf = "abc" };
    const impl = zigraft.Impl(Named, *MyReader){};
    try std.testing.expectEqualStrings("r1", impl.getName(&x));
}

test "default method can call another method" {
    var x = MyReader{ .name = "r1", .buf = "hello" };
    const impl = zigraft.Impl(Reader, *MyReader){};

    var out: [8]u8 = undefined;
    const n = try impl.readAll(&x, out[0..]);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", out[0..n]);
}

test "default method can use field and method together" {
    var x = MyReader{ .name = "r1", .buf = "xyz" };
    const impl = zigraft.Impl(NamedReader, *MyReader){};

    var out: [8]u8 = undefined;
    const n = try impl.readWithLog(&x, out[0..]);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("xyz", out[0..n]);
}

test "pub fn with *Self receiver satisfies interface" {
    zigraft.assertImpl(Reader, *MyReader);
}

test "pub fn with *const Self receiver satisfies interface" {
    zigraft.assertImpl(Named, *const ConstNamed);

    const x = ConstNamed{ .name = "const-name" };
    const impl = zigraft.Impl(Named, *const ConstNamed){};
    try std.testing.expectEqualStrings("const-name", impl.getName(&x));
}

test "pub fn with value receiver satisfies interface" {
    zigraft.assertImpl(Named, ValueNamed);

    const x = ValueNamed{ .name = "value-name" };
    const impl = zigraft.Impl(Named, ValueNamed){};
    try std.testing.expectEqualStrings("value-name", impl.getName(x));
}

test "compose interface: Stream" {
    zigraft.assertImpl(Stream, *MyReader);

    var x = MyReader{ .name = "stream1", .buf = "abcdef" };
    const impl = zigraft.Impl(Stream, *MyReader){};

    const s = try impl.fillBuf(&x);
    try std.testing.expectEqualStrings("abcdef", s);

    impl.consume(&x, 2);

    var out: [8]u8 = undefined;
    const n = try impl.describeAndRead(&x, out[0..]);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("cdef", out[0..n]);
}

test "dyn dispatch works for pointer receiver" {
    var x = MyReader{ .name = "dyn1", .buf = "abc" };
    const dyn_r = zigraft.Dyn(Reader, *MyReader).init(&x);

    var out: [8]u8 = undefined;
    const n = try dyn_r.vtable.read(dyn_r.ctx, out[0..]);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("abc", out[0..n]);
}

test "dyn default method works too" {
    var x = MyReader{ .name = "dyn2", .buf = "hello" };
    const dyn_r = zigraft.Dyn(Reader, *MyReader).init(&x);

    var out: [8]u8 = undefined;
    const n = try dyn_r.vtable.readAll(dyn_r.ctx, out[0..]);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", out[0..n]);
}

test "dyn projection works" {
    var x = MyReader{ .name = "dyn3", .buf = "abcdef" };
    const dyn_stream = zigraft.Dyn(Stream, *MyReader).init(&x);

    var x1 = MyReader2{ .name = "dyn3", .buf = "abcdef" };
    const dyn_stream1 = zigraft.Dyn(Stream, *MyReader2).init(&x1);
    // _ = dyn_stream1;

    if (@TypeOf(dyn_stream) == @TypeOf(dyn_stream1)) {
        std.debug.print("equal stream\n", .{});
    }

    std.debug.print("x: {s} x1: {s}\n", .{ @typeName(@TypeOf(x)), @typeName(@TypeOf(x1)) });

    const dyn_reader = dyn_stream.project(Reader);
    const dyn_seek = dyn_stream.project(Seekable);

    try dyn_seek.vtable.seekTo(dyn_seek.ctx, 3);

    var out: [8]u8 = undefined;
    const n = try dyn_reader.vtable.read(dyn_reader.ctx, out[0..]);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("def", out[0..n]);
}

test "any dyn works" {
    var x = MyReader{ .name = "dyn3", .buf = "abcdef" };
    const dyn_stream = zigraft.AnyDyn(Stream).init(&x);

    var x1 = MyReader2{ .name = "dyn3", .buf = "abcdef" };
    const dyn_stream1 = zigraft.AnyDyn(Stream).init(&x1);
    // _ = dyn_stream1;

    if (@TypeOf(dyn_stream) == @TypeOf(dyn_stream1)) {
        std.debug.print("equal stream\n", .{});
    }

    std.debug.print("x: {s} x1: {s}\n", .{ @typeName(@TypeOf(dyn_stream)), @typeName(@TypeOf(dyn_stream1)) });

    const dyn_reader = dyn_stream.project(Reader);
    const dyn_seek = dyn_stream.project(Seekable);

    std.debug.print("reader: {s} seek: {s}\n", .{ @typeName(@TypeOf(dyn_reader)), @typeName(@TypeOf(dyn_seek)) });

    try dyn_seek.vtable.seekTo(dyn_seek.ctx, 3);

    var out: [8]u8 = undefined;
    const n = try dyn_reader.vtable.read(dyn_reader.ctx, out[0..]);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("def", out[0..n]);
}
