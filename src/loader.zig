const std = @import("std");

pub const Error = error{BadImage};

/// The entry point and initial program break of a loaded image.
pub const Loaded = struct { entry: u32, brk: u32 };

fn u16le(b: []const u8, off: usize) u16 {
    return @as(u16, b[off]) | (@as(u16, b[off + 1]) << 8);
}
fn u32le(b: []const u8, off: usize) u32 {
    return @as(u32, b[off]) | (@as(u32, b[off + 1]) << 8) | (@as(u32, b[off + 2]) << 16) | (@as(u32, b[off + 3]) << 24);
}
fn putU32(b: []u8, off: usize, v: u32) void {
    b[off] = @truncate(v);
    b[off + 1] = @truncate(v >> 8);
    b[off + 2] = @truncate(v >> 16);
    b[off + 3] = @truncate(v >> 24);
}

/// Boot protocol: the hypervisor publishes this record at guest-physical offset 0 before
/// entering a guest, and the guest kernel reads its machine description from fixed offsets.
/// The register-base and disk fields stay 0 until the device milestones populate them. Page 0
/// is reserved for this record; guest images link above it (TEXT_BASE 0x1000).
pub const BOOTINFO_MAGIC: u32 = 0xB0071F00;
pub const BOOTINFO_VERSION: u32 = 1;

pub const BootInfo = struct {
    vm_id: u32,
    ram_size: u32, // bytes of guest-physical RAM
    mmio_base: u32, // guest-physical base of the device window
    console_reg: u32 = 0,
    timer_reg: u32 = 0,
    rtc_reg: u32 = 0,
    rng_reg: u32 = 0,
    blk_reg: u32 = 0,
    disk_blocks: u32 = 0,
    block_size: u32 = 0,
    cmdline_flags: u32 = 0, // bit 0: auto-login (skip the login gate)
};

/// Field byte offsets within the BootInfo page (guest reads these directly).
pub const BI_MAGIC: usize = 0x00;
pub const BI_VERSION: usize = 0x04;
pub const BI_VM_ID: usize = 0x08;
pub const BI_RAM_SIZE: usize = 0x0C;
pub const BI_MMIO_BASE: usize = 0x10;
pub const BI_CONSOLE_REG: usize = 0x14;
pub const BI_TIMER_REG: usize = 0x18;
pub const BI_RTC_REG: usize = 0x1C;
pub const BI_RNG_REG: usize = 0x20;
pub const BI_BLK_REG: usize = 0x24;
pub const BI_DISK_BLOCKS: usize = 0x28;
pub const BI_BLOCK_SIZE: usize = 0x2C;
pub const BI_CMDLINE_FLAGS: usize = 0x30;

test "writeBootInfo lays fields out little-endian at their fixed offsets" {
    var page = [_]u8{0} ** 0x100;
    writeBootInfo(&page, .{ .vm_id = 3, .ram_size = 128 * 1024 * 1024, .mmio_base = 0x20000000, .console_reg = 0x20000000 });
    try std.testing.expectEqual(BOOTINFO_MAGIC, u32le(&page, BI_MAGIC));
    try std.testing.expectEqual(@as(u32, BOOTINFO_VERSION), u32le(&page, BI_VERSION));
    try std.testing.expectEqual(@as(u32, 3), u32le(&page, BI_VM_ID));
    try std.testing.expectEqual(@as(u32, 128 * 1024 * 1024), u32le(&page, BI_RAM_SIZE));
    try std.testing.expectEqual(@as(u32, 0x20000000), u32le(&page, BI_MMIO_BASE));
    try std.testing.expectEqual(@as(u32, 0x20000000), u32le(&page, BI_CONSOLE_REG));
    try std.testing.expectEqual(@as(u32, 0), u32le(&page, BI_TIMER_REG));
}

/// Write the BootInfo record at the base of a guest partition (guest-physical 0).
pub fn writeBootInfo(part: []u8, info: BootInfo) void {
    putU32(part, BI_MAGIC, BOOTINFO_MAGIC);
    putU32(part, BI_VERSION, BOOTINFO_VERSION);
    putU32(part, BI_VM_ID, info.vm_id);
    putU32(part, BI_RAM_SIZE, info.ram_size);
    putU32(part, BI_MMIO_BASE, info.mmio_base);
    putU32(part, BI_CONSOLE_REG, info.console_reg);
    putU32(part, BI_TIMER_REG, info.timer_reg);
    putU32(part, BI_RTC_REG, info.rtc_reg);
    putU32(part, BI_RNG_REG, info.rng_reg);
    putU32(part, BI_BLK_REG, info.blk_reg);
    putU32(part, BI_DISK_BLOCKS, info.disk_blocks);
    putU32(part, BI_BLOCK_SIZE, info.block_size);
    putU32(part, BI_CMDLINE_FLAGS, info.cmdline_flags);
}

/// Copies a TBX object's loadable sections into `ram` at their link addresses and returns the
/// entry point and program break. `ram` must already be zeroed so NOBITS regions read as zero.
pub fn load(ram: []u8, tbx: []const u8) Error!Loaded {
    if (tbx.len < 32 or !std.mem.eql(u8, tbx[0..4], "TBX\x7f")) return error.BadImage;
    const entry = u32le(tbx, 8);
    const sh_off = u32le(tbx, 16);
    const n_sh = u16le(tbx, 20);
    const entsize = u16le(tbx, 22);

    var end: u32 = 0;
    var i: usize = 0;
    while (i < n_sh) : (i += 1) {
        const h = sh_off + i * entsize;
        if (h + 20 > tbx.len) return error.BadImage;
        const typ = u16le(tbx, h + 4);
        const vaddr = u32le(tbx, h + 8);
        const off = u32le(tbx, h + 12);
        const size = u32le(tbx, h + 16);
        if (typ == 1) {
            if (off + size > tbx.len or vaddr + size > ram.len) return error.BadImage;
            @memcpy(ram[vaddr .. vaddr + size], tbx[off .. off + size]);
            if (vaddr + size > end) end = vaddr + size;
        } else if (typ == 2) {
            if (vaddr + size > ram.len) return error.BadImage;
            if (vaddr + size > end) end = vaddr + size;
        }
    }
    return .{ .entry = entry, .brk = (end + 15) & ~@as(u32, 15) };
}
