.text
.entry _start
_start:
    li r1, h_trap
    csrw 0x605, r1
    li r1, 0x100
    csrw 0x602, r1
    li r1, 0
    bra h_enter

h_trap:
    csrw 0x640, r1
    li r1, 0x700
    lw r1, [r1, 0]
    slli r1, r1, 7
    addi r1, r1, 0x600
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
    csrr r2, 0x641
    sw r2, [r1, 64]
    csrr r2, 0x101
    sw r2, [r1, 72]
    csrr r2, 0x600
    sw r2, [r1, 76]
    csrr r2, 0x105
    sw r2, [r1, 80]
    csrr r2, 0x141
    sw r2, [r1, 84]
    csrr r2, 0x100
    sw r2, [r1, 88]

    csrr r3, 0x642
    li r4, 0x80000005
    cmp r3, r4
    beq h_sched
    li r4, 10
    cmp r3, r4
    beq h_dead
    li r4, 23
    cmp r3, r4
    beq h_mmio
    li r4, 21
    cmp r3, r4
    beq h_mmio
    hlt

h_mmio:
    csrr r5, 0x643
    li r6, 0x10000000
    cmp r5, r6
    bne h_halt
    csrr r7, 0x64A
    srli r8, r7, 21
    andi r8, r8, 0xF
    slli r9, r8, 2
    add r9, r1, r9
    srli r10, r7, 25
    li r11, 0x38
    cmp r10, r11
    bge h_st
    sw r0, [r9, 0]
    bra h_adv
h_st:
    lw r12, [r9, 0]
    li r13, 0x10000000
    sb r12, [r13, 0]
h_adv:
    lw r14, [r1, 64]
    addi r14, r14, 4
    sw r14, [r1, 64]
    csrw 0x641, r14
    lw r2, [r1, 76]
    csrw 0x600, r2
    lw r2, [r1, 72]
    csrw 0x101, r2
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

h_sched:
    li r1, 0x700
    lw r1, [r1, 0]
    xori r2, r1, 1
    slli r3, r2, 7
    addi r3, r3, 0x600
    lw r4, [r3, 68]
    tst r4, r4
    bne h_enter
    or r1, r2, r0
    bra h_enter

h_dead:
    li r1, 0x700
    lw r1, [r1, 0]
    slli r2, r1, 7
    addi r2, r2, 0x600
    li r3, 1
    sw r3, [r2, 68]
    xori r4, r1, 1
    slli r5, r4, 7
    addi r5, r5, 0x600
    lw r6, [r5, 68]
    tst r6, r6
    bne h_halt
    or r1, r4, r0
    bra h_enter

h_halt:
    hlt

h_enter:
    li r2, 0x700
    sw r1, [r2, 0]
    slli r3, r1, 1
    addi r3, r3, 16
    li r4, 0x80000000
    or r3, r3, r4
    csrw 0x680, r3
    csrr r5, 0x64D
    addi r5, r5, 20
    csrw 0x64D, r5
    slli r6, r1, 7
    addi r6, r6, 0x600
    lw r7, [r6, 64]
    csrw 0x641, r7
    lw r7, [r6, 76]
    csrw 0x600, r7
    lw r7, [r6, 80]
    csrw 0x105, r7
    lw r7, [r6, 84]
    csrw 0x141, r7
    lw r7, [r6, 88]
    csrw 0x100, r7
    lw r7, [r6, 72]
    csrw 0x101, r7
    lw r1, [r6, 4]
    lw r2, [r6, 8]
    lw r3, [r6, 12]
    lw r4, [r6, 16]
    lw r5, [r6, 20]
    lw r7, [r6, 28]
    lw r8, [r6, 32]
    lw r9, [r6, 36]
    lw r10, [r6, 40]
    lw r11, [r6, 44]
    lw r12, [r6, 48]
    lw r13, [r6, 52]
    lw r14, [r6, 56]
    lw r15, [r6, 60]
    lw r6, [r6, 24]
    hret
