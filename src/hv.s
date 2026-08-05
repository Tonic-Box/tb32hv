.text
.entry _start
_start:
    li r3, 0x10000000
    li r4, msg
loop:
    lbu r5, [r4, 0]
    tst r5, r5
    beq done
    sb r5, [r3, 0]
    addi r4, r4, 1
    bra loop
done:
    hlt
.rodata
msg: .asciz "tb32hv: hypervisor online\n"
