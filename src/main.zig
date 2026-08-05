const std = @import("std");
const tb32 = @import("tb32");
const loader = @import("loader.zig");
const machine = @import("machine.zig");

const RAM_SIZE: usize = 64 * 1024 * 1024;
const NVMS: u32 = 2;
const S2_BASE: u32 = 0x10000;
const GUEST_BASE: u32 = 0x20000;
const PARTITION: u32 = 0x10000;
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

    var v: u32 = 0;
    while (v < NVMS) : (v += 1) {
        const part = GUEST_BASE + v * PARTITION;
        _ = try loader.load(ram[part..], guest_tbx);
        ram[part + 0x100] = @intCast(v + 1);
        buildStage2(ram, S2_BASE + v * 0x2000, part);
        putU32(ram, 0x600 + v * 0x80 + 64, 0x1000);
        putU32(ram, 0x600 + v * 0x80 + 76, 3);
    }

    var m = machine.Machine{ .ram = ram };
    var hart = tb32.Hart{ .mode = .hypervisor };
    hart.cpu.pc = hv_img.entry;

    run(&hart, &m);
}

/// Builds one guest's stage-2 page table (rooted at `root`) mapping the guest's physical pages
/// onto the host partition at `part`, and leaving the virtual UART aperture unmapped so guest
/// access traps to the hypervisor. Each guest gets a disjoint partition, isolating them.
fn buildStage2(ram: []u8, root: u32, part: u32) void {
    const l2 = root + 0x1000;
    putU32(ram, root, l2 | PTE_V);
    var i: u32 = 0;
    while (i < GUEST_PAGES) : (i += 1) {
        putU32(ram, l2 + i * 4, (part + i * 0x1000) | PTE_RWX | PTE_V);
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
        if (hart.v) hart.time +%= 1;
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
