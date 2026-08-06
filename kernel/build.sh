#!/usr/bin/env bash
# Build the guest kernel image: freestanding C via tbc, spliced with the hand-written
# boot/trap assembly, assembled by the native TB32 assembler into kernel.tbx.
set -e
cd "$(dirname "$0")"

TBC=../../zig/toolchain/tbc.py
TB32=../../libtb32/zig-out/bin/tb32
[ -f "$TB32.exe" ] && TB32="$TB32.exe"

cp ../../zig/userland/tbcsr.h tbcsr.h
python "$TBC" kernel.c -freestanding -o kernel_body.s
# boot.s first so _start is at TEXT_BASE (the guest starts executing there).
cat boot.s kernel_body.s > kernel_full.s
"$TB32" kernel_full.s -o kernel.tbx
cp kernel.tbx ../src/kernel.tbx
echo "built kernel.tbx ($(wc -c < kernel.tbx) bytes) -> src/"
