# tb32hv

A Type-1 hypervisor for the **TB32** instruction set, built on the virtualization
extension in [libtb32](https://github.com/Tonic-Box/libtb32).

`tb32hv` runs as TB32 code in the hypervisor privilege mode on a small machine runtime (the
"silicon"): a host program that provides physical RAM and a console UART and executes the TB32-V
CPU core. Guests run as de-privileged TB32 operating systems under two-stage address translation,
isolated from one another and from the hypervisor.

## Build and run

```
zig build run     # boot the hypervisor on the machine runtime
zig build test    # unit tests
```

Requires Zig 0.13 to build.
