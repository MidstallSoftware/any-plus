/// Anytype in runtime
pub const Anytype = @import("any+/anytype.zig");

/// An opaque writer type
pub const Anywriter = @import("any+/anywriter.zig");

test {
    _ = Anytype;
    _ = Anywriter;
}
