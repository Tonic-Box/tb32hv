# tb32hv

A faithful **Type-1 hypervisor** for the **TB32** instruction set, built on the virtualization
extension in [libtb32](https://github.com/Tonic-Box/libtb32).

`tb32hv` runs as TB32 code in a dedicated hypervisor privilege mode, boots to an interactive
manager console, and runs de-privileged TB32 guest operating systems under two-stage address
translation - each isolated from the others and from the hypervisor. Guests are unmodified: they
program what they believe is real hardware (a UART, their own page tables), and the hypervisor
traps and emulates.

## What is running

The system is layered, lowest to highest:

- **The machine runtime ("the silicon")** - a small Zig host (`src/machine.zig`, `src/main.zig`)
  that provides physical RAM and a memory-mapped console UART and executes the TB32-V CPU core
  from libtb32. This is the emulated hardware the hypervisor runs on.
- **The hypervisor** (`src/hv.s`) - TB32 code running in **H mode**. It owns physical memory and
  the console, builds per-guest stage-2 page tables, schedules and context-switches VMs, emulates
  each guest's virtual devices by trap-and-emulate, and drives the manager console.
- **The guests** (`src/guest.s`) - TB32 programs running de-privileged. A guest runs its kernel
  in **VS** (guest supervisor) and its user processes in **VU** (guest user), manages its own
  stage-1 paging, and does I/O to a virtual UART.

Every guest memory access is translated twice: `guest-virtual ->(guest page tables)->
guest-physical ->(hypervisor stage-2)-> host-physical`. The guest owns the top stage; the
hypervisor owns the bottom stage, which is where isolation comes from - a guest cannot escape its
partition no matter what its own page tables say.

## The TB32-V extension (in libtb32)

- **Privilege modes** U / S / H, plus a virtualization (V) bit giving guest **VS** and **VU**.
- **Control/status registers** (`csrr`/`csrw`) for trap vectors, saved state, page-table bases,
  interrupt state, and the condition flags.
- **Traps** with delegation: guest-user syscalls are delivered directly to the guest kernel; a
  guest kernel's privileged operations and device access trap to the hypervisor.
- **Two-stage address translation** (`satp` for the guest, `hgatp` for the hypervisor) with a
  nested page-table walk.
- **Interrupts and a hypervisor timer** for interrupt injection and preemptive scheduling.

## Build and run

```
zig build run     # boot the hypervisor to the manager console
zig build test    # unit tests
```

Requires Zig 0.13 to build.

## Manager console

Booting drops you at the hypervisor prompt. Commands (single key):

- `l` - list VM slots and their state
- `c` - create a VM in the next free slot
- `k N` - destroy (kill) VM N
- `N` - attach to VM N: the console is routed to that guest (its output to your terminal, your
  keys to its input)
- `i N` - show VM N's saved program counter
- `Ctrl-]` - detach from the attached guest and return to the manager (the guest is paused, not
  stopped, and resumes exactly where it left off when re-attached)
- `q` - power off

The bundled guest prints its id and then echoes input; type `x` to make it exit.

## License

[MIT](LICENSE)
