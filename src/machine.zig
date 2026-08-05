const std = @import("std");

/// Physical address of the console UART transmit register. A byte written here is emitted to
/// the host terminal.
pub const UART_TX: u32 = 0x10000000;

/// The physical machine: a flat host-physical RAM plus a memory-mapped console UART. This is
/// the "silicon" the hypervisor runs on; it decodes the physical address space for the CPU core.
pub const Machine = struct {
    ram: []u8,

    pub fn read8(self: *Machine, a: u32) ?u8 {
        if (a < self.ram.len) return self.ram[a];
        return null;
    }

    pub fn write8(self: *Machine, a: u32, v: u8) bool {
        if (a == UART_TX) {
            std.io.getStdOut().writer().writeByte(v) catch {};
            return true;
        }
        if (a < self.ram.len) {
            self.ram[a] = v;
            return true;
        }
        return false;
    }
};
