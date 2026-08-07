//! wasm32 entry: exposes the browser/node shim (boot/stdin_push/run/out_*) over the same HV +
//! guest-kernel platform the native build runs, with single-threaded I/O (no host stdio/threads).
const std = @import("std");
const tb32 = @import("tb32");
const loader = @import("loader.zig");
const machine = @import("machine.zig");

const S2_BASE: u32 = 0x10000;
const S2_STRIDE: u32 = 0x40000;
const GUEST_BASE: u32 = 0x100000;
const PARTITION: u32 = 32 * 1024 * 1024; // one guest, sized past the kernel's frame pool
const RAM_SIZE: usize = GUEST_BASE + PARTITION + 0x100000;
const DISK_BLOCKS: u32 = 1024;
const PTE_V: u32 = 1;
const PTE_RWX: u32 = 2 | 4 | 8;
const STEPS_PER_MS: u64 = 1000;

var ram: [RAM_SIZE]u8 = undefined;
var disk: [DISK_BLOCKS * machine.BLOCK_SIZE]u8 = undefined;
var asm_arena: [1 << 19]u8 = undefined; // scratch to assemble hv.s at boot
var image_buf: [DISK_BLOCKS * machine.BLOCK_SIZE]u8 = undefined; // input staging + FS snapshot buffer
var g_restored: bool = false;
var hart: tb32.Hart = undefined;
var m: machine.Machine = undefined;
var booted: bool = false;

const kernel_tbx = @embedFile("kernel.tbx");
const disk_img = @embedFile("disk.img");
const hv_src = @embedFile("hv.s");

fn getU32(a: u32) u32 {
    return @as(u32, ram[a]) | (@as(u32, ram[a + 1]) << 8) | (@as(u32, ram[a + 2]) << 16) | (@as(u32, ram[a + 3]) << 24);
}
fn putU32(a: u32, v: u32) void {
    ram[a] = @truncate(v);
    ram[a + 1] = @truncate(v >> 8);
    ram[a + 2] = @truncate(v >> 16);
    ram[a + 3] = @truncate(v >> 24);
}
fn mapRange(root: u32, next: *u32, gpa: u32, hpa: u32, size: u32, perms: u32) void {
    var off: u32 = 0;
    while (off < size) : (off += 0x1000) {
        const ga = gpa + off;
        const l1i = (ga >> 22) & 0x3FF;
        var l2 = getU32(root + l1i * 4) & 0xFFFFF000;
        if (l2 == 0) {
            l2 = next.*;
            next.* += 0x1000;
            putU32(root + l1i * 4, l2 | PTE_V);
        }
        const l2i = (ga >> 12) & 0x3FF;
        putU32(l2 + l2i * 4, (hpa + off) | perms);
    }
}

export fn image_ptr() u32 {
    return @intFromPtr(&image_buf);
}
export fn out_ptr() u32 {
    return @intFromPtr(&m.out_buf);
}
export fn out_len() u32 {
    return m.out_n;
}
export fn out_reset() void {
    m.out_n = 0;
}
export fn stdin_push(len: u32) void {
    var i: u32 = 0;
    while (i < len and i < image_buf.len) : (i += 1) m.wasmPush(image_buf[i]);
}

export fn disk_ptr() u32 {
    return @intFromPtr(&disk);
}
export fn disk_len() u32 {
    return disk.len;
}
// Boot fresh (fresh=true loads the embedded default disk; false keeps whatever the host loaded into
// the disk buffer, e.g. a snapshot restored from IndexedDB).
fn bootImpl(seed: u32, fresh: bool) void {
    booted = false;
    @memset(ram[0..], 0);
    if (fresh) @memcpy(disk[0..disk_img.len], disk_img);
    var fba = std.heap.FixedBufferAllocator.init(&asm_arena);
    var diag: tb32.Diagnostic = .{};
    const hv_tbx = tb32.assembleDiag(fba.allocator(), hv_src, &diag) catch return;
    const hv_img = loader.load(ram[0..], hv_tbx) catch return;
    _ = loader.load(ram[GUEST_BASE..], kernel_tbx) catch return;
    loader.writeBootInfo(ram[GUEST_BASE..], .{
        .vm_id = 1,
        .ram_size = PARTITION,
        .mmio_base = machine.DEV_BASE,
        .console_reg = machine.DEV_BASE + machine.CON_TX,
        .rtc_reg = machine.DEV_BASE + machine.RTC_SECS,
        .rng_reg = machine.DEV_BASE + machine.RNG_OUT,
        .blk_reg = machine.DEV_BASE + machine.BLK_CAPACITY,
        .disk_blocks = DISK_BLOCKS,
        .block_size = machine.BLOCK_SIZE,
    });
    const root = S2_BASE;
    var next = root + 0x1000;
    mapRange(root, &next, 0, GUEST_BASE, PARTITION, PTE_RWX | PTE_V);
    mapRange(root, &next, machine.DEV_BASE, machine.DEV_BASE, machine.DEV_SIZE, PTE_RWX | PTE_V);
    m = machine.Machine{ .ram = ram[0..], .disk = disk[0..], .wasm = true, .epoch = 0 };
    m.rng_state = if (seed == 0) 0x1F123BB5 else seed;
    hart = tb32.Hart{ .mode = .hypervisor };
    hart.cpu.pc = hv_img.entry;
    // auto-drive the HV manager: create VM0 ('c') and attach to it ('1').
    m.wasmPush('c');
    m.wasmPush('1');
    booted = true;
}

export fn boot(seed: u32) void {
    bootImpl(seed, true);
}
export fn boot_disk(seed: u32) void {
    bootImpl(seed, false);
}

export fn run(max: u32) u32 {
    if (!booted) return 2;
    m.yielded = false;
    var i: u32 = 0;
    while (i < max) : (i += 1) {
        if (hart.v) hart.time +%= 1;
        m.rtc_ms = @truncate(hart.time / STEPS_PER_MS);
        m.rtc_secs = m.epoch +% (m.rtc_ms / 1000);
        switch (tb32.stepV(&hart, &m)) {
            .ok => {},
            else => return 3,
        }
        if (m.yielded) return 1;
    }
    return 0;
}

export fn fg_euid() u32 {
    return m.fg_euid_val;
}

// ---- terminal.js introspection surface (cwd/user/home from the guest's published buffer) ----
fn introU32(off: u32) u32 {
    if (m.introspect_gpa == 0) return 0;
    return getU32(GUEST_BASE + m.introspect_gpa + off);
}
fn introAddr(off: u32) u32 {
    return @intFromPtr(&ram[GUEST_BASE + m.introspect_gpa + off]);
}
export fn cwd_len_get() u32 {
    return introU32(0);
}
export fn cwd_ptr() u32 {
    return introAddr(12);
}
export fn fg_user() u32 {
    return introU32(4);
}
export fn fg_user_ptr() u32 {
    return introAddr(76);
}
export fn fg_home() u32 {
    return introU32(8);
}
export fn fg_home_ptr() u32 {
    return introAddr(108);
}
export fn fg_shell() u32 {
    return 1;
}
export fn fg_raw() u32 {
    return 0;
}
export fn reboot_pending() u32 {
    return 0;
}
export fn set_echo(on: u32) void {
    _ = on;
}
export fn set_winsize(rows: u32, cols: u32) void {
    if (rows > 0) m.win_rows = rows;
    if (cols > 0) m.win_cols = cols;
}
export fn set_clock(secs: u32) void {
    m.epoch = secs;
}
export fn set_clock_ms(ms: u32) void {
    _ = ms;
}
export fn seed_urandom(s: u32) void {
    m.rng_state = if (s == 0) 1 else s;
}
export fn boot_login(seed: u32) void {
    bootImpl(seed, !g_restored);
}
export fn fs_snapshot() u32 {
    @memcpy(image_buf[0..disk.len], disk[0..disk.len]);
    return disk.len;
}
export fn fs_restore(n: u32) void {
    const k = @min(n, disk.len);
    @memcpy(disk[0..k], image_buf[0..k]);
    g_restored = true;
}

// ---- tab-completion: list a directory by parsing the guest FS out of the disk image ----
const BS: u32 = machine.BLOCK_SIZE;
fn dsk32(off: u32) u32 {
    return @as(u32, disk[off]) | (@as(u32, disk[off + 1]) << 8) | (@as(u32, disk[off + 2]) << 16) | (@as(u32, disk[off + 3]) << 24);
}
fn inoField(ino: u32, f: u32) u32 {
    return dsk32(dsk32(4) * BS + ino * 64 + f);
}
fn dirLookup(dino: u32, name: []const u8) u32 {
    const blk = inoField(dino, 20) * BS;
    var i: u32 = 0;
    while (i < 128) : (i += 1) {
        const e = blk + i * 32;
        const ino = dsk32(e);
        if (ino == 0) continue;
        var k: u32 = 0;
        while (k < name.len and k < 27 and disk[e + 4 + k] == name[k]) : (k += 1) {}
        if (k == name.len and disk[e + 4 + k] == 0) return ino;
    }
    return 0;
}
fn nameiHost(path: []const u8) u32 {
    var ino: u32 = 1;
    var i: usize = if (path.len > 0 and path[0] == '/') 1 else 0;
    while (i < path.len) {
        var j = i;
        while (j < path.len and path[j] != '/') j += 1;
        if (j > i) {
            ino = dirLookup(ino, path[i..j]);
            if (ino == 0) return 0;
        }
        i = j + 1;
    }
    return ino;
}
fn outByte(b: u8) void {
    if (m.out_n < m.out_buf.len) {
        m.out_buf[m.out_n] = b;
        m.out_n += 1;
    }
}
var pathbuf: [512]u8 = undefined;

/// Resolve a completion path to an absolute one: an absolute path is used as-is; a relative path
/// (including "." and "./x") is joined onto the guest's published cwd, so tab-completion of file
/// arguments works in the current directory (the host FS walker only knows absolute paths).
fn resolveDirPath(input: []const u8) []const u8 {
    if (input.len > 0 and input[0] == '/') return input;
    var n: usize = 0;
    if (m.introspect_gpa != 0) {
        const clen = getU32(GUEST_BASE + m.introspect_gpa);
        var k: u32 = 0;
        while (k < clen and n < pathbuf.len) : (k += 1) {
            pathbuf[n] = ram[GUEST_BASE + m.introspect_gpa + 12 + k];
            n += 1;
        }
    }
    if (n == 0) {
        pathbuf[0] = '/';
        n = 1;
    }
    var rest = input;
    if (rest.len == 1 and rest[0] == '.') rest = rest[1..];
    if (rest.len >= 2 and rest[0] == '.' and rest[1] == '/') rest = rest[2..];
    if (rest.len != 0) {
        if (pathbuf[n - 1] != '/' and n < pathbuf.len) {
            pathbuf[n] = '/';
            n += 1;
        }
        var k: usize = 0;
        while (k < rest.len and n < pathbuf.len) : (k += 1) {
            pathbuf[n] = rest[k];
            n += 1;
        }
    }
    return pathbuf[0..n];
}

export fn dir_list(pathlen: u32) void {
    m.out_n = 0;
    const ino = nameiHost(resolveDirPath(image_buf[0..pathlen]));
    if (ino == 0 or inoField(ino, 0) != 2) return;
    const blk = inoField(ino, 20) * BS;
    var i: u32 = 0;
    while (i < 128) : (i += 1) {
        const e = blk + i * 32;
        const cino = dsk32(e);
        if (cino == 0) continue;
        outByte(if (inoField(cino, 0) == 2) 'd' else '-');
        outByte(' ');
        var k: u32 = 0;
        while (k < 27 and disk[e + 4 + k] != 0) : (k += 1) outByte(disk[e + 4 + k]);
        outByte('\n');
    }
}
