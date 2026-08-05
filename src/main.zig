const std = @import("std");
const tb32 = @import("tb32");
const loader = @import("loader.zig");
const machine = @import("machine.zig");

const RAM_SIZE: usize = 64 * 1024 * 1024;
const S2_ROOT: u32 = 0x10000;
const S2_L2: u32 = 0x11000;
const GUEST_BASE: u32 = 0x20000;
const GUEST_PAGES: u32 = 16;

const PTE_V: u32 = 1;
const PTE_RWX: u32 = 2 | 4 | 8;

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.allocator();

    var diag: tb32.Diagnostic = .{};
    const hv_tbx = tb32.assembleDiag(gpa, @embedFile("hv.s"), &diag) catch |e| {
        std.debug.print("tb32hv: hypervisor image failed to assemble: line {d}: {s}\n", .{ diag.line, diag.message });
        return e;
    };
    defer gpa.free(hv_tbx);
    const guest_tbx = tb32.assembleDiag(gpa, @embedFile("guest.s"), &diag) catch |e| {
        std.debug.print("tb32hv: guest image failed to assemble: line {d}: {s}\n", .{ diag.line, diag.message });
        return e;
    };
    defer gpa.free(guest_tbx);

    const ram = try gpa.alloc(u8, RAM_SIZE);
    defer gpa.free(ram);
    @memset(ram, 0);

    const hv_img = try loader.load(ram, hv_tbx);
    _ = try loader.load(ram[GUEST_BASE..], guest_tbx);
    buildStage2(ram);

    var m = machine.Machine{ .ram = ram };
    var hart = tb32.Hart{ .mode = .hypervisor };
    hart.cpu.pc = hv_img.entry;

    run(&hart, &m);
}

/// Builds the guest's stage-2 page table: an identity map of the guest's physical pages onto
/// the host frames at `GUEST_BASE`, leaving the virtual UART aperture unmapped so guest access
/// traps to the hypervisor.
fn buildStage2(ram: []u8) void {
    putU32(ram, S2_ROOT, S2_L2 | PTE_V);
    var i: u32 = 0;
    while (i < GUEST_PAGES) : (i += 1) {
        putU32(ram, S2_L2 + i * 4, (GUEST_BASE + i * 0x1000) | PTE_RWX | PTE_V);
    }
}

fn putU32(ram: []u8, addr: u32, v: u32) void {
    ram[addr] = @truncate(v);
    ram[addr + 1] = @truncate(v >> 8);
    ram[addr + 2] = @truncate(v >> 16);
    ram[addr + 3] = @truncate(v >> 24);
}

/// Executes the hypervisor hart, advancing the machine timer, until it halts.
fn run(hart: *tb32.Hart, m: *machine.Machine) void {
    var guard: u64 = 0;
    while (guard < 1_000_000_000) : (guard += 1) {
        hart.time +%= 1;
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
