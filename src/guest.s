.text
.entry _start
_start:
    li r3, 0x10000000
    li r4, gmsg
gloop:
    lbu r5, [r4, 0]
    tst r5, r5
    beq gid
    sb r5, [r3, 0]
    addi r4, r4, 1
    bra gloop
gid:
    li r6, 0x100
    lbu r7, [r6, 0]
    addi r7, r7, 0x30
    sb r7, [r3, 0]
    li r8, 0x0A
    sb r8, [r3, 0]
    sys
.rodata
gmsg: .asciz "guest "
