//! Everything `zig build test` runs: the parts that make no system calls.

test {
    _ = @import("control.zig");
    _ = @import("config.zig");
    _ = @import("undervolt_code.zig");
}
