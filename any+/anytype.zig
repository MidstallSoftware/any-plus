const std = @import("std");
const Self = @This();

type: []const u8,
size: usize = 0,
ptr: *anyopaque,

/// Initializes a runtime anytype from a comptime anytype.
pub inline fn init(value: anytype) Self {
    return initExplicit(@TypeOf(value), value);
}

/// Explicitly initialize a runtime anytype to fit the type T.
pub inline fn initExplicit(comptime T: type, value: T) Self {
    var size: usize = @sizeOf(T);
    const ptr: *anyopaque = switch (@typeInfo(T)) {
        .Int, .ComptimeInt => @ptrFromInt(value),
        .Float, .ComptimeFloat => @ptrFromInt(@as(usize, @bitCast(@as(f128, @floatCast(value))))),
        .Enum => @ptrFromInt(@intFromEnum(value)),
        .Struct, .Union => @constCast(&value),
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
