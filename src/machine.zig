const std = @import("std");

/// Base of the host-physical device window. The hypervisor maps this range into each guest's
/// stage-2 (at the same guest-physical address), so guest MMIO is decoded here directly rather
/// than trapping to the hypervisor. It sits above host RAM, so a plain RAM access never reaches
/// it. Registers are byte-addressed within a single 4 KiB page; new virtual devices are added as
/// decode cases here. Multi-byte registers are read/written a byte at a time (the CPU's word
/// accesses become four in-order byte accesses), so a register's value stays stable across the
/// four bytes of one instruction.
pub const DEV_BASE: u32 = 0x20000000;
pub const DEV_SIZE: u32 = 0x1000;

/// Device register offsets from DEV_BASE.
pub const CON_TX: u32 = 0x00; // write a byte -> host terminal
pub const CON_RX: u32 = 0x04; // read a byte of host input; 0 at end of input
pub const RTC_SECS: u32 = 0x08; // wall-clock epoch seconds (read-only)
pub const RTC_MS: u32 = 0x0C; // monotonic milliseconds (read-only)
pub const RNG_OUT: u32 = 0x10; // next 32-bit random value (read advances the stream)
pub const RNG_SEED: u32 = 0x14; // seed the RNG (write); lets the host make runs deterministic
pub const BLK_CAPACITY: u32 = 0x18; // number of blocks on the disk (read-only)
pub const BLK_BLOCKSIZE: u32 = 0x1C; // bytes per block (read-only)
pub const BLK_LBA: u32 = 0x20; // select a block; a write resets the byte cursor to 0
pub const BLK_DATA: u32 = 0x24; // read/write the selected block's bytes in sequence (auto-advances)
pub const BLK_STATUS: u32 = 0x28; // 0 = ok, 1 = the cursor is past the end of the disk (read-only)

pub const BLOCK_SIZE: u32 = 4096;

fn xorshift32(x: u32) u32 {
    var v = x;
    v ^= v << 13;
    v ^= v >> 17;
    v ^= v << 5;
    return v;
}

/// The physical machine: flat host-physical RAM plus the memory-mapped device window. This is
/// the "silicon" the hypervisor runs on; it decodes the physical address space for the CPU core.
pub const Machine = struct {
    ram: []u8,
    epoch: u32 = 0, // wall-clock seconds at boot; rtc_secs = epoch + elapsed
    rtc_secs: u32 = 0,
    rtc_ms: u32 = 0,
    rng_state: u32 = 0x1F123BB5,
    rng_latch: u32 = 0,
    disk: []u8 = &[_]u8{}, // block-device backing store
    blk_lba: u32 = 0,
    blk_off: u32 = 0,
    blk_status: u32 = 0,

    pub fn read8(self: *Machine, a: u32) ?u8 {
        if (a >= DEV_BASE and a < DEV_BASE + DEV_SIZE) return self.devRead(a - DEV_BASE);
        if (a < self.ram.len) return self.ram[a];
        return null;
    }

    pub fn write8(self: *Machine, a: u32, v: u8) bool {
        if (a >= DEV_BASE and a < DEV_BASE + DEV_SIZE) return self.devWrite(a - DEV_BASE, v);
        if (a < self.ram.len) {
            self.ram[a] = v;
            return true;
        }
        return false;
    }

    fn devRead(self: *Machine, off: u32) u8 {
        if (off == CON_RX) return std.io.getStdIn().reader().readByte() catch 0;
        const shift: u5 = @intCast((off & 3) * 8);
        return switch (off & ~@as(u32, 3)) {
            RTC_SECS => @truncate(self.rtc_secs >> shift),
            RTC_MS => @truncate(self.rtc_ms >> shift),
            RNG_OUT => blk: {
                // reading the low byte latches a fresh value the whole word reads from.
                if (off & 3 == 0) {
                    self.rng_state = xorshift32(self.rng_state);
                    self.rng_latch = self.rng_state;
                }
                break :blk @truncate(self.rng_latch >> shift);
            },
            BLK_CAPACITY => @truncate(@as(u32, @intCast(self.disk.len / BLOCK_SIZE)) >> shift),
            BLK_BLOCKSIZE => @truncate(BLOCK_SIZE >> shift),
            BLK_LBA => @truncate(self.blk_lba >> shift),
            BLK_STATUS => @truncate(self.blk_status >> shift),
            BLK_DATA => blk: {
                // streaming data port: each access reads the next byte of the selected block.
                const pos = @as(usize, self.blk_lba) * BLOCK_SIZE + self.blk_off;
                const b: u8 = if (pos < self.disk.len) self.disk[pos] else nope: {
                    self.blk_status = 1;
                    break :nope 0;
                };
                self.blk_off = (self.blk_off + 1) % BLOCK_SIZE;
                break :blk b;
            },
            else => 0,
        };
    }

    fn devWrite(self: *Machine, off: u32, v: u8) bool {
        if (off == CON_TX) {
            std.io.getStdOut().writer().writeByte(v) catch {};
            return true;
        }
        const shift: u5 = @intCast((off & 3) * 8);
        switch (off & ~@as(u32, 3)) {
            RNG_SEED => {
                const mask = ~(@as(u32, 0xFF) << shift);
                self.rng_state = (self.rng_state & mask) | (@as(u32, v) << shift);
            },
            BLK_LBA => {
                const mask = ~(@as(u32, 0xFF) << shift);
                self.blk_lba = (self.blk_lba & mask) | (@as(u32, v) << shift);
                self.blk_off = 0;
                self.blk_status = 0;
            },
            BLK_DATA => {
                const pos = @as(usize, self.blk_lba) * BLOCK_SIZE + self.blk_off;
                if (pos < self.disk.len) self.disk[pos] = v else self.blk_status = 1;
                self.blk_off = (self.blk_off + 1) % BLOCK_SIZE;
            },
            else => {},
        }
        return true;
    }
};

test "RTC registers read the machine's virtual clock, byte by byte" {
    var m = Machine{ .ram = &[_]u8{}, .rtc_secs = 0x11223344, .rtc_ms = 0xAABBCCDD };
    try std.testing.expectEqual(@as(u8, 0x44), m.devRead(RTC_SECS));
    try std.testing.expectEqual(@as(u8, 0x33), m.devRead(RTC_SECS + 1));
    try std.testing.expectEqual(@as(u8, 0x22), m.devRead(RTC_SECS + 2));
    try std.testing.expectEqual(@as(u8, 0x11), m.devRead(RTC_SECS + 3));
    try std.testing.expectEqual(@as(u8, 0xDD), m.devRead(RTC_MS));
    try std.testing.expectEqual(@as(u8, 0xAA), m.devRead(RTC_MS + 3));
}

fn readWord(m: *Machine, off: u32) u32 {
    return @as(u32, m.devRead(off)) | (@as(u32, m.devRead(off + 1)) << 8) |
        (@as(u32, m.devRead(off + 2)) << 16) | (@as(u32, m.devRead(off + 3)) << 24);
}

test "RNG advances each word read, and a written seed makes it deterministic" {
    var m = Machine{ .ram = &[_]u8{} };
    const a = readWord(&m, RNG_OUT);
    const b = readWord(&m, RNG_OUT);
    try std.testing.expect(a != b); // successive reads differ
    // seed it and read the stream, then reseed with the same value and confirm it repeats.
    var s: u32 = 0xDEADBEEF;
    var i: u32 = 0;
    while (i < 4) : (i += 1) _ = m.devWrite(RNG_SEED + i, @truncate(s >> @intCast(i * 8)));
    const first = readWord(&m, RNG_OUT);
    s = 0xDEADBEEF;
    i = 0;
    while (i < 4) : (i += 1) _ = m.devWrite(RNG_SEED + i, @truncate(s >> @intCast(i * 8)));
    try std.testing.expectEqual(first, readWord(&m, RNG_OUT));
}

fn writeWord(m: *Machine, off: u32, v: u32) void {
    var i: u32 = 0;
    while (i < 4) : (i += 1) _ = m.devWrite(off + i, @truncate(v >> @intCast(i * 8)));
}

test "block device reports geometry, streams a selected block, and writes back" {
    var disk = [_]u8{0} ** (2 * BLOCK_SIZE);
    disk[0] = 'A';
    disk[1] = 'B';
    disk[BLOCK_SIZE] = 'Z'; // first byte of block 1
    var m = Machine{ .ram = &[_]u8{}, .disk = &disk };
    try std.testing.expectEqual(@as(u32, 2), readWord(&m, BLK_CAPACITY));
    try std.testing.expectEqual(BLOCK_SIZE, readWord(&m, BLK_BLOCKSIZE));
    // select block 0; the streaming port returns its bytes in order.
    writeWord(&m, BLK_LBA, 0);
    try std.testing.expectEqual(@as(u8, 'A'), m.devRead(BLK_DATA));
    try std.testing.expectEqual(@as(u8, 'B'), m.devRead(BLK_DATA));
    // reselecting a block rewinds the cursor; block 1 starts with 'Z'.
    writeWord(&m, BLK_LBA, 1);
    try std.testing.expectEqual(@as(u8, 'Z'), m.devRead(BLK_DATA));
    // write-back: put a byte at block 1 offset 0 and read it back.
    writeWord(&m, BLK_LBA, 1);
    _ = m.devWrite(BLK_DATA, 'Q');
    try std.testing.expectEqual(@as(u8, 'Q'), disk[BLOCK_SIZE]);
    try std.testing.expectEqual(@as(u32, 0), readWord(&m, BLK_STATUS));
}
