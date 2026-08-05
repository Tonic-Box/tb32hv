.text
.entry _start
_start:
    li r3, 0x20000000
    li r6, 0x20000004
    li r7, 0
    lw r8, [r7, 0]
    li r9, 0xB0071F00
    cmp r8, r9
    beq bok
    li r8, 0x21
    sb r8, [r3, 0]
bok:
    li r4, banner
bl:
    lbu r5, [r4, 0]
    tst r5, r5
    beq showid
    sb r5, [r3, 0]
    addi r4, r4, 1
    bra bl
showid:
    li r7, 8
    lbu r8, [r7, 0]
    addi r8, r8, 0x30
    sb r8, [r3, 0]
    li r8, 0x0A
    sb r8, [r3, 0]
    li r7, 0x0C
    lw r12, [r7, 0]
    li r13, 32
rsl:
    addi r13, r13, -4
    srl r14, r12, r13
    andi r14, r14, 0xF
    li r15, 10
    cmp r14, r15
    bge rsa
    addi r14, r14, 0x30
    bra rse
rsa:
    addi r14, r14, 0x57
rse:
    sb r14, [r3, 0]
    tst r13, r13
    bne rsl
    li r14, 0x0A
    sb r14, [r3, 0]
    li r9, 0x04000000
    li r10, 0x48
    sb r10, [r9, 0]
    lbu r11, [r9, 0]
    cmp r11, r10
    bne el
    sb r10, [r3, 0]
    li r10, 0x0A
    sb r10, [r3, 0]
    li r7, tmr_h
    csrw 0x105, r7
    li r7, 0x20
    csrw 0x104, r7
    li r8, 0
    li r7, 0x2000000C
    lw r9, [r7, 0]
    li r10, 1000
    mul r9, r9, r10
    addi r9, r9, 3000
    csrw 0x14D, r9
    li r7, 2
    csrw 0x100, r7
tspin:
    li r7, 3
    cmp r8, r7
    bge dread
    bra tspin
tmr_h:
    csrw 0x140, r12
    li r12, 0x40
    sw r7, [r12, 0]
    sw r9, [r12, 4]
    csrr r7, 0x101
    sw r7, [r12, 8]
    addi r8, r8, 1
    li r7, 0x54
    sb r7, [r3, 0]
    csrr r9, 0x14D
    addi r9, r9, 3000
    csrw 0x14D, r9
    li r7, 0
    csrw 0x144, r7
    li r12, 0x40
    lw r7, [r12, 8]
    csrw 0x101, r7
    lw r9, [r12, 4]
    lw r7, [r12, 0]
    csrr r12, 0x140
    sret
dread:
    li r7, 0x20000020
    sw r0, [r7, 0]
    li r9, 0x20000024
dkl:
    lbu r5, [r9, 0]
    tst r5, r5
    beq hcy
    sb r5, [r3, 0]
    bra dkl
hcy:
    li r7, 0x59
    sb r7, [r3, 0]
    li r7, 2
    sys
    li r7, 0x0A
    sb r7, [r3, 0]
el:
    li r7, 0x20000030
    lbu r5, [r7, 0]
    tst r5, r5
    beq el
    li r7, 0x2000002C
    lbu r5, [r7, 0]
    tst r5, r5
    beq ed
    li r7, 0x78
    cmp r5, r7
    beq ed
    sb r5, [r3, 0]
    bra el
ed:
    li r7, 0
    sys
.rodata
banner: .asciz "vm "
