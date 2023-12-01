const std = @import("std");
const Self = @This();

type: []const u8,
size: usize = 0,
ptr: *anyopaque,

pub inline fn init(value: anytype) Self {
    return initExplicit(@TypeOf(value), value);
}

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

pub inline fn cast(self: Self, comptime T: type) error{InvalidCast}!T {
    if (!std.mem.eql(u8, self.type, @typeName(T))) return error.InvalidCast;

    return switch (@typeInfo(T)) {
        .Int, .ComptimeInt => @intFromPtr(self.ptr),
        .Float, .ComptimeFloat => @floatCast(@as(f128, @bitCast(self.ptr))),
        .Enum => |e| @enumFromInt(@as(e.tag_type, @ptrFromInt(self.ptr))),
        .Struct, .Union => @ptrCast(@alignCast(self.ptr)),
        .Pointer => |p| switch (@typeInfo(p.child)) {
            .Array => blk: {
                const length = @divExact(self.size, @sizeOf(p.child));
                break :blk @as([*]p.child, @ptrCast(@alignCast(self.ptr)))[0..length];
            },
            else => |f| @compileError("Unsupported pointer type: " ++ @tagName(f)),
        },
        else => |f| @compileError("Unsupported type: " ++ @tagName(f)),
    };
}

pub inline fn len(self: Self, comptime T: type) usize {
    const size = switch (@typeInfo(T)) {
        .Pointer => |p| @sizeOf(p.child),
        else => @sizeOf(T),
    };

    return @divExact(self.size, size);
}
