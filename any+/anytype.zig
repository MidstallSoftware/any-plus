const std = @import("std");
const Self = @This();

// TODO: use any-writer when it exists
const PointerFormat = *const fn (*const Self, options: std.fmt.FormatOptions, *std.io.FixedBufferStream([]u8)) error{ NoSpaceLeft, InvalidCast }!void;

type: []const u8,
size: usize = 0,
ptr: ?*anyopaque,
ptrFormat: PointerFormat,

/// Initializes a runtime anytype from a comptime anytype.
pub inline fn init(value: anytype) Self {
    return initExplicit(@TypeOf(value), value);
}

/// Explicitly initialize a runtime anytype to fit the type T.
pub inline fn initExplicit(comptime T: type, value: T) Self {
    var size: usize = @sizeOf(T);
    var ptrFormat: PointerFormat = (struct {
        fn func(t: *const Self, options: std.fmt.FormatOptions, stream: *std.io.FixedBufferStream([]u8)) !void {
            const self: T = t.cast(T) catch return error.NoSpaceLeft;
            return std.fmt.formatType(self, "", options, stream.writer(), 3);
        }
    }).func;

    const ptr: ?*anyopaque = switch (@typeInfo(T)) {
        .Int, .ComptimeInt => @ptrFromInt(value),
        .Float, .ComptimeFloat => @ptrFromInt(@as(u64, @bitCast(@as(f64, @floatCast(value))))),
        .Enum => @ptrFromInt(@intFromEnum(value)),
        .Struct, .Union => blk: {
            ptrFormat = (struct {
                fn func(t: *const Self, options: std.fmt.FormatOptions, stream: *std.io.FixedBufferStream([]u8)) !void {
                    const self: T = t.cast(T) catch return error.NoSpaceLeft;
                    return if (@hasDecl(T, "format")) self.format("", options, stream.writer()) else std.fmt.formatType(self, "", options, stream.writer(), 3);
                }
            }).func;
            break :blk @constCast(&value);
        },
        .Pointer => |p| switch (@typeInfo(p.child)) {
            .Array => blk: {
                size = value.len * @sizeOf(p.child);
                break :blk @ptrCast(@constCast(value.ptr));
            },
            else => |f| @compileError("Unsupported pointer type: " ++ @tagName(f)),
        },
        else => |f| @compileError("Unsupported type: " ++ @tagName(f)),
    };

    return .{
        .type = @typeName(T),
        .size = size,
        .ptr = ptr,
        .ptrFormat = ptrFormat,
    };
}

/// Safely casts from the anytype to the real type.
/// This returns an error if the cast cannot be made safely.
pub inline fn cast(self: Self, comptime T: type) error{InvalidCast}!T {
    if (!std.mem.eql(u8, self.type, @typeName(T))) return error.InvalidCast;
    return self.unsafeCast(T);
}

/// Casts a type without any of the safety
pub inline fn unsafeCast(self: Self, comptime T: type) T {
    return switch (@typeInfo(T)) {
        .Int, .ComptimeInt => @intCast(@intFromPtr(self.ptr)),
        .Float, .ComptimeFloat => @floatCast(@as(f64, @bitCast(@intFromPtr(self.ptr)))),
        .Enum => |e| @enumFromInt(@as(e.tag_type, @ptrFromInt(self.ptr))),
        .Struct, .Union => @as(*T, @ptrCast(@alignCast(self.ptr.?))).*,
        .Pointer => |p| switch (@typeInfo(p.child)) {
            .Array => blk: {
                break :blk @as([*]p.child, @ptrCast(@alignCast(self.ptr.?)))[0..self.len(T)];
            },
            else => |f| @compileError("Unsupported pointer type: " ++ @tagName(f)),
        },
        else => |f| @compileError("Unsupported type: " ++ @tagName(f)),
    };
}

/// Returns the number of elements in the anytype.
/// If 1 is returned, it could be a single element type.
pub inline fn len(self: Self, comptime T: type) usize {
    const size = switch (@typeInfo(T)) {
        .Pointer => |p| @sizeOf(p.child),
        else => @sizeOf(T),
    };

    return @divExact(self.size, size);
}

pub inline fn format(self: *const Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    const size = comptime if (std.mem.indexOf(u8, fmt, "%")) |sizeStart| std.fmt.parseInt(comptime_int, fmt[sizeStart..]) else 0x1000;

    const trunc_msg = "(msg truncated)";
    var buf: [size + trunc_msg.len]u8 = undefined;
    @memset(&buf, 0);

    var stream = std.io.fixedBufferStream(buf[0..size]);
    const result = self.ptrFormat(self, options, &stream);

    if (result == error.NoSpaceLeft) {
        @memcpy(buf[size..], trunc_msg);
        try writer.writeAll(&buf);
    } else if (result == error.InvalidCast) {
        std.debug.panic("Failed to cast {s}", .{self.type});
    } else {
        const end = std.mem.indexOf(u8, &buf, &[_]u8{0}) orelse buf.len;
        try writer.writeAll(buf[0..end]);
    }
}

test "Casting integers and floats" {
    @setEvalBranchQuota(100_000);
    comptime var i: usize = 0;
    inline while (i < std.math.maxInt(u8)) : (i += 1) {
        try std.testing.expectEqual(i, try initExplicit(u8, i).cast(u8));
    }

    try std.testing.expectEqual(@as(f32, 123.456), try initExplicit(f32, 123.456).cast(f32));
}

test "Casting structs and unions" {
    const UnionType = union(enum) {
        a: u32,
        b: [2]u16,
        c: [4]u8,
    };

    const StructType = struct {
        a: u32,
        b: u16,
        c: u8,
    };

    try std.testing.expectEqualDeep(UnionType{
        .a = 4096,
    }, try initExplicit(UnionType, UnionType{
        .a = 4096,
    }).cast(UnionType));

    try std.testing.expectEqualDeep(StructType{
        .a = 4096,
        .b = 1024,
        .c = 255,
    }, try initExplicit(StructType, StructType{
        .a = 4096,
        .b = 1024,
        .c = 255,
    }).cast(StructType));
}

test "Invalid casts" {
    try std.testing.expectError(error.InvalidCast, initExplicit(f32, 123.456).cast(u8));
    try std.testing.expectError(error.InvalidCast, initExplicit(f32, 123.456).cast(f128));
}

test "Anytype formatting" {
    try std.testing.expectFmt("255", "{}", .{initExplicit(u8, 255)});
    try std.testing.expectFmt("1.23456001e+02", "{}", .{initExplicit(f32, 123.456)});
}
