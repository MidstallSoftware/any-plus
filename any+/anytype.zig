const std = @import("std");
const Self = @This();

// TODO: use any-writer when it exists
const PointerFormat = *const fn (*anyopaque, options: std.fmt.FormatOptions, std.io.FixedBufferStream(u8)) anyerror!void;

type: []const u8,
size: usize = 0,
ptr: *anyopaque,
ptrFormat: ?PointerFormat = null,

/// Initializes a runtime anytype from a comptime anytype.
pub inline fn init(value: anytype) Self {
    return initExplicit(@TypeOf(value), value);
}

/// Explicitly initialize a runtime anytype to fit the type T.
pub inline fn initExplicit(comptime T: type, value: T) Self {
    var size: usize = @sizeOf(T);
    var ptrFormat: ?PointerFormat = null;
    const ptr: *anyopaque = switch (@typeInfo(T)) {
        .Int, .ComptimeInt => @ptrFromInt(value),
        .Float, .ComptimeFloat => @ptrFromInt(@as(usize, @bitCast(@as(f128, @floatCast(value))))),
        .Enum => @ptrFromInt(@intFromEnum(value)),
        .Struct, .Union => blk: {
            if (@hasDecl(T, "format")) {
                ptrFormat = (struct {
                    fn func(selfPointer: *anyopaque, options: std.fmt.FormatOptions, stream: std.io.FixedBufferStream(u8)) !void {
                        const self: *T = @ptrCast(@alignCast(selfPointer));
                        return self.format("", options, stream.writer());
                    }
                }).func;
            }
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
        .Int, .ComptimeInt => @intFromPtr(self.ptr),
        .Float, .ComptimeFloat => @floatCast(@as(f128, @bitCast(self.ptr))),
        .Enum => |e| @enumFromInt(@as(e.tag_type, @ptrFromInt(self.ptr))),
        .Struct, .Union => @ptrCast(@alignCast(self.ptr)),
        .Pointer => |p| switch (@typeInfo(p.child)) {
            .Array => blk: {
                break :blk @as([*]p.child, @ptrCast(@alignCast(self.ptr)))[0..self.len(T)];
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

pub inline fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    if (self.ptrFormat) |ptrFormat| {
        const size = comptime if (std.mem.indexOf(u8, fmt, "%")) |sizeStart| std.fmt.parseInt(comptime_int, fmt[sizeStart..]) else 0x1000;

        const trunc_msg = "(msg truncated)";
        var buf: [size + trunc_msg.len]u8 = undefined;

        const stream = std.io.fixedBufferStream(buf[0..size]);
        ptrFormat(self.ptr, options, stream) catch |err| switch (err) {
            error.NoSpaceLeft => blk: {
                @memcpy(buf[size..], trunc_msg);
                break :blk &buf;
            },
            else => return err,
        };

        try writer.writeAll(buf);
    } else {
        try writer.writeAll(@typeName(Self));
        try writer.print("{{ .size = {}, .len = {}, .type = \"{s}\", .ptr = {*} }}", .{
            self.size,
            self.len(),
            self.type,
            self.ptr,
        });
    }
}

test "Casting integers and floats" {
    comptime var i: usize = 0;
    inline while (i < std.math.maxInt(u8)) : (i += 1) {
        try std.testing.expectEqual(i, try initExplicit(u8, i).cast(u8));
    }

    try std.testing.expectEqual(123.456, try initExplicit(f32, 123.456).cast(f32));
}

test "Invalid casts" {
    try std.testing.expectError(error.InvalidCast, initExplicit(f32, 123.456).cast(u8));
    try std.testing.expectError(error.InvalidCast, initExplicit(f32, 123.456).cast(f128));
}
