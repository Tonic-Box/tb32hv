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
comptime {
    if (RAM_SIZE > @as(usize, tb32.MAX_RAM_PAGES) << 12)
        @compileError("RAM_SIZE exceeds the JIT block cache's page coverage; raise MAX_RAM_PAGES in libtb32/src/jit.zig");
}
const DISK_BLOCKS: u32 = 1024;
const PTE_V: u32 = 1;
const PTE_RWX: u32 = 2 | 4 | 8;
const STEPS_PER_MS: u64 = 1000;

var ram: [RAM_SIZE]u8 = undefined;
var disk: [DISK_BLOCKS * machine.BLOCK_SIZE]u8 = undefined;
var asm_arena: [1 << 19]u8 = undefined; // scratch to assemble hv.s at boot
var input_buf: [1 << 16]u8 = undefined; // stdin + tab-completion staging (FS snapshots go straight through disk_ptr)
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
    return @intFromPtr(&input_buf);
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
    while (i < len and i < input_buf.len) : (i += 1) m.wasmPush(input_buf[i]);
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
    jit_state.hot_head = 0;
    jit_state.hot_tail = 0;
    jit_state.flushAll();
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
    if (m.rtc_real) m.rtc_secs = m.epoch;
    var i: u32 = 0;
    while (i < max) : (i += 1) {
        if (hart.v) {
            hart.time +%= 1;
            if (!m.rtc_real) {
                m.rtc_acc +%= 1;
                if (m.rtc_acc >= STEPS_PER_MS) {
                    m.rtc_acc = 0;
                    m.rtc_ms +%= 1;
                    m.rtc_secs = m.epoch +% (m.rtc_ms / 1000);
                }
            }
        }
        switch (tb32.stepV(&hart, &m)) {
            .ok => {},
            else => return 3,
        }
        if (m.yielded) return 1;
    }
    return 0;
}

// ---- JIT accelerator ----
// The decoded-block cache lives beside the interpreter; the gates only ever call run(), which is
// left byte-for-byte unchanged. run_jit mirrors run()'s bookkeeping but executes cached
// straight-line blocks in the guest context, falling back to a single interpreter step for
// terminators, safepoints, and any non-guest slice.
// Uninitialized so its multi-megabyte cache lands in zero-filled wasm memory, not the module's
// data section. bootImpl initializes it; the monotonically advancing epoch invalidates every
// block left over from a previous boot.
var jit_state: tb32.Jit = undefined;

// Advances the guest clock by n retired instructions, matching run()'s per-instruction
// bookkeeping. Callers invoke this only for guest-context instructions (run() gates the same
// work on hart.v); a whole cached block is guest by construction (jitEligible required it).
inline fn tickGuest(n: u32) void {
    hart.time +%= n;
    if (!m.rtc_real) {
        m.rtc_acc +%= n;
        while (m.rtc_acc >= STEPS_PER_MS) {
            m.rtc_acc -= @intCast(STEPS_PER_MS);
            m.rtc_ms +%= 1;
            m.rtc_secs = m.epoch +% (m.rtc_ms / 1000);
        }
    }
}

const JIT_HOT_THRESH: u32 = 16;
const JIT_REQ_PERIOD: u32 = 16;
var jit_c_count: u32 = 0;
var jit_i_count: u32 = 0;
var jit_disp_count: u32 = 0;
var jit_deopt_count: u32 = 0;
export fn jit_stat_compiled() u32 {
    return jit_c_count;
}
export fn jit_stat_interp() u32 {
    return jit_i_count;
}
export fn jit_stat_disp() u32 {
    return jit_disp_count;
}
export fn jit_stat_deopt() u32 {
    return jit_deopt_count;
}
export fn jit_stat_reset() void {
    jit_c_count = 0;
    jit_i_count = 0;
    jit_disp_count = 0;
    jit_deopt_count = 0;
}

export fn run_jit(max: u32) u32 {
    if (!booted) return 2;
    m.yielded = false;
    if (m.rtc_real) m.rtc_secs = m.epoch;
    hart.jit = &jit_state;
    defer hart.jit = null;
    var i: u32 = 0;
    while (i < max) {
        if (tb32.jitEligible(&hart)) {
            if (tb32.jitFetch(&hart, &m)) |fpa| {
                if (tb32.jitBlock(&hart, &m, &jit_state, fpa)) |blk| {
                    if (blk.slot >= 0 and blk.clen >= 1 and blk.clen <= max - i and jit_slot_owner[@intCast(blk.slot)] == fpa) {
                        jit_disp_count +%= 1;
                        const n: u32 = @intCast(jit_fn[@intCast(blk.slot)](@intCast(max - i)));
                        if (n == 0) jit_deopt_count +%= 1;
                        if (n > 0) {
                            jit_c_count +%= n;
                            tickGuest(n);
                            i += n;
                            if (m.yielded) return 1;
                            continue;
                        }
                    }
                    const pre_mode: u8 = @intFromEnum(hart.mode);
                    const pre_sum: u8 = if (hart.csr.sum) 1 else 0;
                    const n = tb32.runBlockInterp(&hart, &m, &jit_state, blk, max - i);
                    if (n > 0) {
                        jit_i_count +%= n;
                        if (blk.slot == -1) {
                            blk.hits +%= 1;
                            if (blk.hits >= JIT_HOT_THRESH and (blk.hits & (JIT_REQ_PERIOD - 1)) == 0) {
                                blk.cmode = pre_mode;
                                blk.csum = pre_sum;
                                jit_state.requestCompile(fpa);
                            }
                        }
                        tickGuest(n);
                        i += n;
                        if (m.yielded) return 1;
                        continue;
                    }
                }
            }
        }
        if (hart.v) tickGuest(1);
        switch (tb32.stepV(&hart, &m)) {
            .ok => {},
            else => return 3,
        }
        i += 1;
        if (m.yielded) return 1;
    }
    return 0;
}

// Browser compile pipeline: jit_next_hot yields a physical block key needing compilation,
// jit_translate emits its wasm to jit_code_buf, and jit_bind records the installed table slot.
export fn jit_next_hot() u32 {
    return jit_state.nextHot();
}
const JIT_MIN_CLEN: u32 = 6;

export fn jit_translate(fpa: u32) u32 {
    const blk = jit_state.lookup(fpa) orelse return 0;
    var words: [64]u32 = undefined;
    var k: u32 = 0;
    while (k < blk.len) : (k += 1) words[k] = blk.insns[k].word;
    const ctx = tb32.JitCtx{
        .reg_base = @intFromPtr(&hart.cpu.r[0]),
        .flags_addr = @intFromPtr(&hart.cpu.f),
        .pc_addr = @intFromPtr(&hart.cpu.pc),
        .mode_addr = @intFromPtr(&hart.mode),
        .sum_addr = @intFromPtr(&hart.csr.sum),
        .tlb_base = @intFromPtr(&hart.tlb[0]),
        .tlbgen_addr = @intFromPtr(&hart.tlb_gen),
        .ram_base = @intFromPtr(&ram[0]),
        .ram_len = @intCast(ram.len),
        .codepage_addr = @intFromPtr(&jit_state.code_page[0]),
        .user = blk.cmode == 0,
        .sum = blk.csum != 0,
    };
    const r = tb32.emitBlock(&jit_code_buf, words[0..blk.len], ctx);
    // Compile blocks with enough arithmetic to amortize the call/framing overhead, or any block
    // that inlines a memory access (which saves the whole interpreter translate+dispatch path).
    if (r.clen < 2 or (r.clen < JIT_MIN_CLEN and !r.has_mem)) {
        jit_clen_val = 0;
        return 0;
    }
    jit_clen_val = r.clen;
    return r.len;
}
export fn jit_bind(fpa: u32, slot: u32, clen: u32) void {
    jit_state.bind(fpa, @intCast(slot), clen);
    jit_slot_owner[slot] = fpa;
}
export fn jit_mark_bad(fpa: u32) void {
    jit_state.markBad(fpa);
}
export fn jit_reset() void {
    jit_state.flushAll();
}

// ---- JIT accelerator ABI ----
// Absolute linear-memory addresses of hart/machine state, resolved once and baked into
// browser-generated wasm block code as i32 constants (robust to Zig struct layout). Lets
// generated blocks read/write guest registers, PC, flags, time and the TLB directly.
export fn jit_ram_base() u32 {
    return @intFromPtr(&ram[0]);
}
export fn jit_ram_len() u32 {
    return @intCast(ram.len);
}
export fn jit_reg_base() u32 {
    return @intFromPtr(&hart.cpu.r[0]);
}
export fn jit_pc_addr() u32 {
    return @intFromPtr(&hart.cpu.pc);
}
export fn jit_flags_addr() u32 {
    return @intFromPtr(&hart.cpu.f);
}
export fn jit_insnpc_addr() u32 {
    return @intFromPtr(&hart.cpu.insn_pc);
}
export fn jit_time_addr() u32 {
    return @intFromPtr(&hart.time);
}
export fn jit_tlb_base() u32 {
    return @intFromPtr(&hart.tlb[0]);
}
export fn jit_tlb_stride() u32 {
    return @intCast(@sizeOf(@TypeOf(hart.tlb[0])));
}
export fn jit_tlbgen_addr() u32 {
    return @intFromPtr(&hart.tlb_gen);
}
export fn jit_mode_addr() u32 {
    return @intFromPtr(&hart.mode);
}
export fn jit_v_addr() u32 {
    return @intFromPtr(&hart.v);
}
export fn jit_sum_addr() u32 {
    return @intFromPtr(&hart.csr.sum);
}
export fn jit_codepage_addr() u32 {
    return @intFromPtr(&jit_state.code_page[0]);
}

// ---- JIT block table + emit pipeline ----
// A fixed set of table slots, each pre-seeded with a distinct stub so the linker materializes it
// in the exported funcref table. The browser overwrites a slot (Table.set at jit_slot_index(i))
// with a compiled block and the runner dispatches it via jit_call; the module itself stays
// import-free, so the gates instantiate it unchanged.
const JIT_SLOTS: u32 = 16384;
const BlockFn = *const fn (i32) callconv(.C) i32;

fn Stub(comptime i: u32) type {
    return struct {
        fn f(_: i32) callconv(.C) i32 {
            return @intCast(i);
        }
    };
}

var jit_fn: [JIT_SLOTS]BlockFn = init: {
    @setEvalBranchQuota(JIT_SLOTS * 8);
    var a: [JIT_SLOTS]BlockFn = undefined;
    for (0..JIT_SLOTS) |i| a[i] = Stub(i).f;
    break :init a;
};
var jit_code_buf: [16384]u8 = undefined;
var jit_probe_scratch: u32 = 0;
// Owner (block key) of each table slot. When the browser reuses a slot for a new block it rebinds
// the owner, so a previously-compiled block whose slot was reclaimed fails the dispatch guard and
// safely falls back to the interpreter (and re-requests compilation). Enables slot recycling so a
// long session - build then play - is not capped by the fixed table size.
var jit_slot_owner: [JIT_SLOTS]u32 = undefined;

export fn jit_slots() u32 {
    return JIT_SLOTS;
}
export fn jit_slot_index(i: u32) u32 {
    return @intFromPtr(jit_fn[i]);
}
export fn jit_call(i: u32, budget: i32) i32 {
    return jit_fn[i](budget);
}
export fn jit_code_ptr() u32 {
    return @intFromPtr(&jit_code_buf[0]);
}
export fn jit_probe_scratch_addr() u32 {
    return @intFromPtr(&jit_probe_scratch);
}
export fn jit_emit_probe(addr: u32, val: u32) u32 {
    return tb32.emitProbe(&jit_code_buf, addr, val);
}

var jit_words_buf: [64]u32 = undefined;
var jit_clen_val: u32 = 0;
export fn jit_words_ptr() u32 {
    return @intFromPtr(&jit_words_buf[0]);
}
export fn jit_last_clen() u32 {
    return jit_clen_val;
}
export fn jit_emit_block(nwords: u32, reg_base: u32, flags_addr: u32, pc_addr: u32, mode_addr: u32, sum_addr: u32, tlb_base: u32, tlbgen_addr: u32, ram_base: u32, ram_len: u32, codepage_addr: u32, user: u32, sum: u32) u32 {
    const ctx = tb32.JitCtx{
        .reg_base = reg_base,
        .flags_addr = flags_addr,
        .pc_addr = pc_addr,
        .mode_addr = mode_addr,
        .sum_addr = sum_addr,
        .tlb_base = tlb_base,
        .tlbgen_addr = tlbgen_addr,
        .ram_base = ram_base,
        .ram_len = ram_len,
        .codepage_addr = codepage_addr,
        .user = user != 0,
        .sum = sum != 0,
    };
    const r = tb32.emitBlock(&jit_code_buf, jit_words_buf[0..nwords], ctx);
    jit_clen_val = r.clen;
    return r.len;
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
    m.rtc_ms = ms;
    m.rtc_real = true;
}
export fn seed_urandom(s: u32) void {
    m.rng_state = if (s == 0) 1 else s;
}
export fn boot_login(seed: u32) void {
    bootImpl(seed, !g_restored);
}
// The host reads and writes the block device directly through disk_ptr/disk_len; a restore just
// marks the disk as already-populated so the next boot keeps it instead of reformatting.
export fn mark_restored() void {
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
    // Build the raw (possibly relative) absolute path: cwd + "/" + input, or input if absolute.
    var raw: [512]u8 = undefined;
    var rn: usize = 0;
    if (input.len > 0 and input[0] == '/') {
        var k: usize = 0;
        while (k < input.len and rn < raw.len) : (k += 1) {
            raw[rn] = input[k];
            rn += 1;
        }
    } else {
        if (m.introspect_gpa != 0) {
            const clen = getU32(GUEST_BASE + m.introspect_gpa);
            var k: u32 = 0;
            while (k < clen and rn < raw.len) : (k += 1) {
                raw[rn] = ram[GUEST_BASE + m.introspect_gpa + 12 + k];
                rn += 1;
            }
        }
        if (rn == 0) {
            raw[0] = '/';
            rn = 1;
        }
        if (raw[rn - 1] != '/' and rn < raw.len) {
            raw[rn] = '/';
            rn += 1;
        }
        var k: usize = 0;
        while (k < input.len and rn < raw.len) : (k += 1) {
            raw[rn] = input[k];
            rn += 1;
        }
    }
    // Normalize: resolve "." (skip) and ".." (pop) components into pathbuf.
    var n: usize = 1;
    pathbuf[0] = '/';
    var i: usize = 0;
    while (i < rn) {
        while (i < rn and raw[i] == '/') i += 1;
        var j = i;
        while (j < rn and raw[j] != '/') j += 1;
        const comp = raw[i..j];
        i = j;
        if (comp.len == 0) continue;
        if (comp.len == 1 and comp[0] == '.') continue;
        if (comp.len == 2 and comp[0] == '.' and comp[1] == '.') {
            var li: usize = 0;
            var p: usize = 0;
            while (p < n) : (p += 1) {
                if (pathbuf[p] == '/') li = p;
            }
            n = if (li == 0) 1 else li;
            continue;
        }
        if (pathbuf[n - 1] != '/' and n < pathbuf.len) {
            pathbuf[n] = '/';
            n += 1;
        }
        var k: usize = 0;
        while (k < comp.len and n < pathbuf.len) : (k += 1) {
            pathbuf[n] = comp[k];
            n += 1;
        }
    }
    return pathbuf[0..n];
}

export fn dir_list(pathlen: u32) void {
    m.out_n = 0;
    const ino = nameiHost(resolveDirPath(input_buf[0..pathlen]));
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
