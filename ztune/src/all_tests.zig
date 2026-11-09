//! Everything `zig build test` runs: the parts that make no system calls.

test {
    _ = @import("profile.zig");
    _ = @import("config.zig");
    _ = @import("journal.zig");
    _ = @import("wifi.zig");
    _ = @import("calibrate.zig");
    _ = @import("text.zig");
    _ = @import("main.zig");
}
