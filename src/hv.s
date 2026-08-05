.text
.entry _start
_start:
    li r1, 0x80000010
    csrw 0x680, r1
    li r1, h_trap
    csrw 0x605, r1
    li r1, 0x1000
    csrw 0x641, r1
    li r1, 3
    csrw 0x600, r1
    hret

h_trap:
    csrw 0x640, r1
    li r1, 0x800
    sw r0, [r1, 0]
    sw r2, [r1, 8]
    sw r3, [r1, 12]
    sw r4, [r1, 16]
    sw r5, [r1, 20]
    sw r6, [r1, 24]
    sw r7, [r1, 28]
    sw r8, [r1, 32]
    sw r9, [r1, 36]
    sw r10, [r1, 40]
    sw r11, [r1, 44]
    sw r12, [r1, 48]
    sw r13, [r1, 52]
    sw r14, [r1, 56]
    sw r15, [r1, 60]
    csrr r2, 0x640
    sw r2, [r1, 4]

    csrr r3, 0x642
    li r4, 10
    cmp r3, r4
    beq h_exit
    li r4, 23
    cmp r3, r4
    beq h_mmio
    li r4, 21
    cmp r3, r4
    beq h_mmio
    hlt

h_exit:
    hlt

h_mmio:
    csrr r5, 0x643
    li r6, 0x10000000
    cmp r5, r6
    bne h_exit
    csrr r7, 0x64A
    srli r8, r7, 21
    andi r8, r8, 0xF
    slli r8, r8, 2
    li r11, 0x800
    add r11, r11, r8
    srli r9, r7, 25
    li r10, 0x38
    cmp r9, r10
    bge h_store
    sw r0, [r11, 0]
    bra h_advance
h_store:
    lw r12, [r11, 0]
    li r13, 0x10000000
    sb r12, [r13, 0]
h_advance:
    csrr r14, 0x641
    addi r14, r14, 4
    csrw 0x641, r14

h_restore:
    li r1, 0x800
    lw r2, [r1, 8]
    lw r3, [r1, 12]
    lw r4, [r1, 16]
    lw r5, [r1, 20]
    lw r6, [r1, 24]
    lw r7, [r1, 28]
    lw r8, [r1, 32]
    lw r9, [r1, 36]
    lw r10, [r1, 40]
    lw r11, [r1, 44]
    lw r12, [r1, 48]
    lw r13, [r1, 52]
    lw r14, [r1, 56]
    lw r15, [r1, 60]
    lw r1, [r1, 4]
    hret
