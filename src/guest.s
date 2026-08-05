.text
.entry _start
_start:
    li r1, k_trap
    csrw 0x105, r1
    li r1, user
    csrw 0x141, r1
    csrw 0x100, r0
    sret

k_trap:
    li r2, 2
    cmp r7, r2
    beq k_exit
    li r2, 0x10000000
    sb r1, [r2, 0]
    csrr r2, 0x141
    addi r2, r2, 4
    csrw 0x141, r2
    sret
k_exit:
    sys

user:
    li r3, 0x100
    lbu r4, [r3, 0]
    addi r4, r4, 0x30
    li r5, umsg
uloop:
    lbu r1, [r5, 0]
    tst r1, r1
    beq uid
    li r7, 1
    sys
    addi r5, r5, 1
    bra uloop
uid:
    or r1, r4, r0
    li r7, 1
    sys
    li r1, 0x0A
    li r7, 1
    sys
    li r7, 2
    sys
.rodata
umsg: .asciz "guest OS syscall from vm "
