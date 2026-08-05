.text
.entry _start
_start:
    li r3, 0x10000000
    li r4, gmsg
gloop:
    lbu r5, [r4, 0]
    tst r5, r5
    beq gdone
    sb r5, [r3, 0]
    addi r4, r4, 1
    bra gloop
gdone:
    sys
.rodata
gmsg: .asciz "hello from the guest\n"
