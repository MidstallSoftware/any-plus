const std = @import("std");
const Self = @This();

pub const Error = anyerror;
const PointerWrite = *const fn (*const Self, []const u8) Error!void;

pub const Writer = std.io.Writer(Self, Error, write);

type: []const u8,
ptr: *anyopaque,
ptrWrite: PointerWrite,

pub inline fn init(writer: anytype) Self {
    return initExplicit(@TypeOf(writer), writer);
}

pub inline fn initExplicit(comptime T: type, writer: T) Self {
    return .{
        .type = @typeName(T),
        .ptr = @constCast(&writer),
        .ptrWrite = (struct {
            fn func(self: *const Self, buf: []const u8) Error!void {
                if (!std.mem.eql(u8, self.type, @typeName(T))) return error.InvalidCast;
                const w: *T = @ptrCast(@alignCast(self.ptr));
                return w.write(buf);
            }
        }).func,
    };
}

pub fn write(self: Self, buf: []const u8) Error!void {
    return self.ptrWrite(&self, buf);
}
