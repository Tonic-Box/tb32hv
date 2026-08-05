const std = @import("std");
const tb32 = @import("tb32");
const loader = @import("loader.zig");
const machine = @import("machine.zig");

const NVMS: u32 = 2;
const S2_BASE: u32 = 0x10000;
const S2_STRIDE: u32 = 0x40000; // per-VM stage-2 arena: root + bump-allocated L2 pages (64 pages)
const GUEST_BASE: u32 = 0x100000; // first guest partition (past the HV image + stage-2 tables)
const PARTITION: u32 = 128 * 1024 * 1024; // per-guest physical RAM
// Host RAM must hold every guest partition; the device window sits above it (machine.DEV_BASE).
const RAM_SIZE: usize = GUEST_BASE + NVMS * PARTITION + 0x100000;

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
        const root = S2_BASE + v * S2_STRIDE;
        var next = root + 0x1000;
        buildStage2(ram, root, &next, part);
    }

    var m = machine.Machine{ .ram = ram };
    var hart = tb32.Hart{ .mode = .hypervisor };
    hart.cpu.pc = hv_img.entry;

    run(&hart, &m);
}

/// Maps `size` bytes of guest-physical [gpa, gpa+size) onto host-physical [hpa, ...) in the
/// two-level stage-2 rooted at `root`, allocating L2 tables from the bump pointer `next` (which
/// starts just past the root page and stays within this VM's stage-2 arena). 4 KiB pages.
fn mapRange(ram: []u8, root: u32, next: *u32, gpa: u32, hpa: u32, size: u32, perms: u32) void {
    var off: u32 = 0;
    while (off < size) : (off += 0x1000) {
        const ga = gpa + off;
        const l1i = (ga >> 22) & 0x3FF;
        var l2 = getU32(ram, root + l1i * 4) & 0xFFFFF000;
        if (l2 == 0) {
            l2 = next.*;
            next.* += 0x1000;
            putU32(ram, root + l1i * 4, l2 | PTE_V);
        }
        const l2i = (ga >> 12) & 0x3FF;
        putU32(ram, l2 + l2i * 4, (hpa + off) | perms);
    }
}

/// Builds one guest's stage-2 page table (rooted at `root`) mapping its 128 MiB of guest-physical
/// RAM onto the disjoint host partition at `part` (isolating guests), plus the device window
/// (guest-physical machine.DEV_BASE -> the host device page) so guest MMIO is decoded by the
/// machine directly instead of trapping.
fn buildStage2(ram: []u8, root: u32, next: *u32, part: u32) void {
    mapRange(ram, root, next, 0, part, PARTITION, PTE_RWX | PTE_V);
    mapRange(ram, root, next, machine.DEV_BASE, machine.DEV_BASE, machine.DEV_SIZE, PTE_RWX | PTE_V);
}

fn putU32(ram: []u8, addr: u32, v: u32) void {
    ram[addr] = @truncate(v);
    ram[addr + 1] = @truncate(v >> 8);
    ram[addr + 2] = @truncate(v >> 16);
    ram[addr + 3] = @truncate(v >> 24);
}

fn getU32(ram: []const u8, addr: u32) u32 {
    return @as(u32, ram[addr]) | (@as(u32, ram[addr + 1]) << 8) |
        (@as(u32, ram[addr + 2]) << 16) | (@as(u32, ram[addr + 3]) << 24);
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

// Walk the two-level stage-2 by hand and return the host-physical address a guest-physical
// address maps to, or null if unmapped.
fn s2walk(ram: []const u8, root: u32, gpa: u32) ?u32 {
    const l1e = getU32(ram, root + ((gpa >> 22) & 0x3FF) * 4);
    if (l1e & PTE_V == 0) return null;
    const l2e = getU32(ram, (l1e & 0xFFFFF000) + ((gpa >> 12) & 0x3FF) * 4);
    if (l2e & PTE_V == 0) return null;
    return (l2e & 0xFFFFF000) | (gpa & 0xFFF);
}

test "buildStage2 maps 128 MiB of guest RAM to its partition and the device page identity" {
    const gpa = std.testing.allocator;
    const ram = try gpa.alloc(u8, S2_BASE + S2_STRIDE);
    defer gpa.free(ram);
    @memset(ram, 0);
    const root: u32 = S2_BASE;
    const part: u32 = 0x40000000;
    var next: u32 = root + 0x1000;
    buildStage2(ram, root, &next, part);
    // low, middle and top guest-physical RAM pages map linearly onto the host partition.
    try std.testing.expectEqual(@as(?u32, part + 0x123), s2walk(ram, root, 0x123));
    try std.testing.expectEqual(@as(?u32, part + 0x04000000 + 0x10), s2walk(ram, root, 0x04000000 + 0x10));
    try std.testing.expectEqual(@as(?u32, part + PARTITION - 0x1000), s2walk(ram, root, PARTITION - 0x1000));
    // one page past the partition is unmapped.
    try std.testing.expectEqual(@as(?u32, null), s2walk(ram, root, PARTITION));
    // the device window maps guest-physical DEV_BASE onto the host device window (identity).
    try std.testing.expectEqual(@as(?u32, machine.DEV_BASE + 4), s2walk(ram, root, machine.DEV_BASE + 4));
    // the L2 bump allocator stayed within this VM's stage-2 arena.
    try std.testing.expect(next <= root + S2_STRIDE);
}
