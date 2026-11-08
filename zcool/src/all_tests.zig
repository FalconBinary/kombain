//! Everything `zig build test` runs: the parts that make no system calls.

test {
    _ = @import("control.zig");
    _ = @import("config.zig");
    _ = @import("undervolt_code.zig");
    _ = @import("gpus.zig");
    _ = @import("nvidia.zig");
    _ = @import("ec.zig");
    _ = @import("journal.zig");
    _ = @import("menu.zig");
    _ = @import("guard.zig");
}
