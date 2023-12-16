const std = @import("std");
const Self = @This();
const Anywriter = @import("anywriter.zig");

// TODO: use any-writer when it exists
const PointerFormat = *const fn (*const Self, options: std.fmt.FormatOptions, Anywriter.Writer) anyerror!void;

type: []const u8,
size: usize = 0,
ptr: ?*anyopaque,
ptrFormat: PointerFormat,

pub fn Casted(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .Pointer => |p| blk: {
            var baseType = @typeInfo(switch (p.size) {
                .Slice, .Many => []Casted(p.child),
                .One, .C => *Casted(p.child),
            }).Pointer;

            baseType.is_const = p.is_const;
            baseType.is_volatile = p.is_volatile;
            baseType.alignment = p.alignment;
            baseType.address_space = p.address_space;
            break :blk @Type(.{ .Pointer = baseType });
        },
        .Array => |a| []a.child,
        else => T,
    };
}

/// Initializes a runtime anytype from a comptime anytype.
pub inline fn init(value: anytype) Self {
    return initExplicit(@TypeOf(value), value);
}

/// Explicitly initialize a runtime anytype to fit the type T.
pub inline fn initExplicit(comptime T: type, value: T) Self {
    var size: usize = @sizeOf(T);
    var ptrFormat: PointerFormat = (struct {
        fn func(t: *const Self, options: std.fmt.FormatOptions, writer: Anywriter.Writer) !void {
            const self = t.cast(Casted(T)) catch return error.NoSpaceLeft;
            return std.fmt.formatType(self, "any", options, writer, 3);
        }
    }).func;

    const ptr: ?*anyopaque = switch (@typeInfo(T)) {
        .Int, .ComptimeInt => @ptrFromInt(value),
        .Float, .ComptimeFloat => @ptrFromInt(@as(u64, @bitCast(@as(f64, @floatCast(value))))),
        .Enum => @ptrFromInt(@intFromEnum(value)),
        .Struct, .Union => blk: {
            ptrFormat = (struct {
                fn func(t: *const Self, options: std.fmt.FormatOptions, writer: Anywriter.Writer) !void {
                    const self = t.cast(Casted(T)) catch return error.NoSpaceLeft;
                    return if (@hasDecl(T, "format")) self.format("", options, writer) else std.fmt.formatType(self, "", options, writer, 3);
                }
            }).func;
            break :blk @constCast(&value);
        },
        .Array => |a| blk: {
            size = value.len * @sizeOf(a.child);
            break :blk @ptrCast(@constCast(&value));
        },
        .Pointer => |p| switch (p.size) {
            .Many, .Slice => blk: {
                size = value.len * @sizeOf(p.child);
                break :blk @ptrCast(@constCast(value));
            },
            .One, .C => @ptrCast(@constCast(value)),
        },
        else => |f| @compileError("Unsupported type: " ++ @tagName(f)),
    };

    return .{
        .type = @typeName(Casted(T)),
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
        .Enum => @enumFromInt(@as(usize, @intFromPtr(self.ptr))),
        .Struct, .Union => @as(*T, @ptrCast(@alignCast(self.ptr.?))).*,
        .Array => |a| @as([*]a.child, @ptrCast(@alignCast(self.ptr.?)))[0..self.len()],
        .Pointer => |p| blk: {
            const t = comptime blkt: {
                var baseType = @typeInfo(switch (p.size) {
                    .Many, .Slice => [*]p.child,
                    .One, .C => *p.child,
                }).Pointer;
                baseType.is_const = p.is_const;
                baseType.is_volatile = p.is_volatile;
                baseType.alignment = p.alignment;
                baseType.address_space = p.address_space;
                break :blkt @Type(.{ .Pointer = baseType });
            };

            break :blk switch (p.size) {
                .Many, .Slice => @as(t, @ptrCast(@alignCast(self.ptr.?)))[0..self.len(T)],
                .One, .C => @as(t, @ptrCast(@alignCast(self.ptr.?))),
            };
        },
        else => |f| @compileError("Unsupported type: " ++ @tagName(f)),
    };
}

/// Returns the number of elements in the anytype.
/// If 1 is returned, it could be a single element type.
pub inline fn len(self: Self, comptime T: type) usize {
    const size = switch (@typeInfo(T)) {
        .Pointer => |p| @sizeOf(p.child),
        .Array => |a| @sizeOf(a.child),
        else => @sizeOf(T),
    };

    return @divExact(self.size, size);
}

pub inline fn format(self: *const Self, comptime _: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    return self.ptrFormat(self, options, Anywriter.init(writer).writer()) catch |err| std.debug.panic("Anywriter failed: {s}", .{@errorName(err)});
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
