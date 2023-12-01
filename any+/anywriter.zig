const std = @import("std");
const Self = @This();

pub const Error = anyerror;
const PointerWrite = *const fn (*const Self, []const u8) Error!usize;

pub const Writer = std.io.Writer(*const Self, Error, write);

type: []const u8,
ptr: *anyopaque,
ptrWrite: PointerWrite,

pub inline fn init(value: anytype) Self {
    return initExplicit(@TypeOf(value), value);
}

pub inline fn initExplicit(comptime T: type, value: T) Self {
    return .{
        .type = @typeName(T),
        .ptr = @constCast(&value),
        .ptrWrite = (struct {
            fn func(self: *const Self, buf: []const u8) Error!usize {
                if (!std.mem.eql(u8, self.type, @typeName(T))) return error.InvalidCast;
                const w: *T = @ptrCast(@alignCast(self.ptr));
                return w.write(buf);
            }
        }).func,
    };
}

pub fn write(self: *const Self, buf: []const u8) Error!usize {
    return self.ptrWrite(self, buf);
}

pub fn writer(self: *const Self) Writer {
    return .{
        .context = self,
    };
}
