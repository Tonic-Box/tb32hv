const std = @import("std");

/// Base of the host-physical device window. The hypervisor maps this range into
/// each guest's stage-2 (at the same guest-physical address), so guest MMIO is
/// decoded here directly rather than trapping to the hypervisor. It sits above
/// host RAM, so a plain RAM access never reaches it. Registers are byte-addressed
/// within a single 4 KiB page; new virtual devices are added as decode cases here.
pub const DEV_BASE: u32 = 0x20000000;
pub const DEV_SIZE: u32 = 0x1000;

/// Console device register offsets (from DEV_BASE).
const CON_TX: u32 = 0x00; // write a byte -> host terminal
const CON_RX: u32 = 0x04; // read a byte of host input; 0 at end of input

/// The physical machine: flat host-physical RAM plus the memory-mapped device
/// window. This is the "silicon" the hypervisor runs on; it decodes the physical
/// address space for the CPU core.
pub const Machine = struct {
    ram: []u8,

    pub fn read8(self: *Machine, a: u32) ?u8 {
        if (a >= DEV_BASE and a < DEV_BASE + DEV_SIZE) return devRead(a - DEV_BASE);
        if (a < self.ram.len) return self.ram[a];
        return null;
    }

    pub fn write8(self: *Machine, a: u32, v: u8) bool {
        if (a >= DEV_BASE and a < DEV_BASE + DEV_SIZE) return devWrite(a - DEV_BASE, v);
        if (a < self.ram.len) {
            self.ram[a] = v;
            return true;
        }
        return false;
    }

    fn devRead(off: u32) u8 {
        if (off == CON_RX) return std.io.getStdIn().reader().readByte() catch 0;
        return 0;
    }

    fn devWrite(off: u32, v: u8) bool {
        if (off == CON_TX) std.io.getStdOut().writer().writeByte(v) catch {};
        return true;
    }
};
