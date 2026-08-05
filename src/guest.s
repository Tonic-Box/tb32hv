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
el:
    lbu r5, [r6, 0]
    tst r5, r5
    beq ed
    li r7, 0x78
    cmp r5, r7
    beq ed
    sb r5, [r3, 0]
    bra el
ed:
    sys
.rodata
banner: .asciz "vm "
