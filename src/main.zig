const std = @import("std");
const tb32 = @import("tb32");
const loader = @import("loader.zig");
const machine = @import("machine.zig");

const RAM_SIZE: usize = 64 * 1024 * 1024;

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.allocator();

    var diag: tb32.Diagnostic = .{};
    const tbx = tb32.assembleDiag(gpa, @embedFile("hv.s"), &diag) catch |e| {
        std.debug.print("tb32hv: hypervisor image failed to assemble: line {d}: {s}\n", .{ diag.line, diag.message });
        return e;
    };
    defer gpa.free(tbx);

    const ram = try gpa.alloc(u8, RAM_SIZE);
    defer gpa.free(ram);
    @memset(ram, 0);

    const image = try loader.load(ram, tbx);

    var m = machine.Machine{ .ram = ram };
    var hart = tb32.Hart{ .mode = .hypervisor };
    hart.cpu.pc = image.entry;

    run(&hart, &m);
}

/// Executes the hypervisor hart until it halts or faults into a stop.
fn run(hart: *tb32.Hart, m: *machine.Machine) void {
    var guard: u64 = 0;
    while (guard < 1_000_000_000) : (guard += 1) {
        switch (tb32.stepV(hart, m)) {
            .ok => {},
            .halt => break,
            .breakpoint => break,
        }
    }
}

test {
    _ = loader;
    _ = machine;
}
