.text
.entry _start
_start:
    li r3, 0x10000000
    li r6, 0x100
    lbu r7, [r6, 0]
    addi r7, r7, 0x30
    li r8, 20
gloop:
    tst r8, r8
    beq gdone
    sb r7, [r3, 0]
    addi r8, r8, -1
    bra gloop
gdone:
    li r9, 0x0A
    sb r9, [r3, 0]
    sys
