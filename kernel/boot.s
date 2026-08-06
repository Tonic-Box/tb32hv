.text
.entry _start
_start:
    li sp, kstack_top
    li r1, trap_entry
    csrw 0x105, r1
    call kmain
    hlt

trap_entry:
    csrw 0x140, r1
    li r1, tf
    sw r2, [r1, 4]
    sw r3, [r1, 8]
    sw r4, [r1, 12]
    sw r5, [r1, 16]
    sw r6, [r1, 20]
    sw r7, [r1, 24]
    sw r8, [r1, 28]
    sw r9, [r1, 32]
    sw r10, [r1, 36]
    sw r11, [r1, 40]
    sw r12, [r1, 44]
    sw r13, [r1, 48]
    sw r14, [r1, 52]
    sw r15, [r1, 56]
    csrr r2, 0x140
    sw r2, [r1, 0]
    csrr r2, 0x141
    sw r2, [r1, 60]
    csrr r2, 0x101
    sw r2, [r1, 64]
    li sp, kstack_top
    call handle_trap
    li r1, tf
    lw r2, [r1, 60]
    addi r2, r2, 4
    csrw 0x141, r2
    lw r2, [r1, 64]
    csrw 0x101, r2
    lw r2, [r1, 4]
    lw r3, [r1, 8]
    lw r4, [r1, 12]
    lw r5, [r1, 16]
    lw r6, [r1, 20]
    lw r7, [r1, 24]
    lw r8, [r1, 28]
    lw r9, [r1, 32]
    lw r10, [r1, 36]
    lw r11, [r1, 40]
    lw r12, [r1, 44]
    lw r13, [r1, 48]
    lw r14, [r1, 52]
    lw r15, [r1, 56]
    lw r1, [r1, 0]
    sret

enter_user:
    csrw 0x141, r1
    li r3, 0
    csrw 0x100, r3
    li r13, ustack_top
    sret

.bss
kstack: .space 8192
kstack_top:
ustack: .space 8192
ustack_top:
