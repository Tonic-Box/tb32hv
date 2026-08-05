.text
.entry _start
_start:
    li r1, h_trap
    csrw 0x605, r1
    li r1, 0x100
    csrw 0x602, r1
    li r1, banner_hv
    call puts

manager:
    li r1, prompt
    call puts
    li r1, 0x10000004
    lbu r2, [r1, 0]
    tst r2, r2
    beq m_quit
    li r3, 0x71
    cmp r2, r3
    beq m_quit
    li r3, 0x6C
    cmp r2, r3
    beq m_list
    li r3, 0x63
    cmp r2, r3
    beq m_create
    li r3, 0x6B
    cmp r2, r3
    beq m_kill
    li r3, 0x31
    cmp r2, r3
    beq m_att0
    li r3, 0x32
    cmp r2, r3
    beq m_att1
    bra manager

m_quit:
    li r1, bye
    call puts
    hlt

m_att0:
    li r1, 0
    bra m_attach
m_att1:
    li r1, 1
m_attach:
    li r2, 0x510
    add r2, r2, r1
    lbu r3, [r2, 0]
    tst r3, r3
    beq m_novm
    li r2, 0x500
    sw r1, [r2, 0]
    li r1, attach
    call puts
    bra h_enter
m_novm:
    li r1, novm
    call puts
    bra manager

m_create:
    li r1, 0x510
    lbu r2, [r1, 0]
    tst r2, r2
    beq c0
    lbu r2, [r1, 1]
    tst r2, r2
    beq c1
    li r1, full
    call puts
    bra manager
c0:
    li r1, 0
    bra cdo
c1:
    li r1, 1
cdo:
    li r2, 0x510
    add r2, r2, r1
    li r3, 1
    sb r3, [r2, 0]
    call reset_vm
    li r1, created
    call puts
    bra manager

m_kill:
    li r1, 0x10000004
    lbu r2, [r1, 0]
    li r3, 0x30
    sub r2, r2, r3
    li r1, 0x510
    add r1, r1, r2
    sb r0, [r1, 0]
    li r1, killed
    call puts
    bra manager

m_list:
    li r1, lst0
    call puts
    li r5, 0x510
    lbu r3, [r5, 0]
    tst r3, r3
    beq lf0
    li r1, sact
    call puts
    bra l1
lf0:
    li r1, sfree
    call puts
l1:
    li r1, lst1
    call puts
    lbu r3, [r5, 1]
    tst r3, r3
    beq lf1
    li r1, sact
    call puts
    bra lend
lf1:
    li r1, sfree
    call puts
lend:
    li r1, nl
    call puts
    bra manager

puts:
    li r3, 0x10000000
putsl:
    lbu r4, [r1, 0]
    tst r4, r4
    beq putsd
    sb r4, [r3, 0]
    addi r1, r1, 1
    bra putsl
putsd:
    ret

reset_vm:
    slli r2, r1, 7
    addi r2, r2, 0x600
    li r3, 0
rvz:
    li r4, 96
    cmp r3, r4
    bge rvs
    add r5, r2, r3
    sw r0, [r5, 0]
    addi r3, r3, 4
    bra rvz
rvs:
    li r3, 0x1000
    sw r3, [r2, 64]
    li r3, 3
    sw r3, [r2, 76]
    ret

h_trap:
    csrw 0x640, r1
    li r1, 0x500
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
    csrr r2, 0x180
    sw r2, [r1, 92]
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
    li r2, 0x500
    lw r2, [r2, 0]
    li r3, 0x510
    add r3, r3, r2
    sb r0, [r3, 0]
    li r1, vmexit
    call puts
    bra manager

h_mmio:
    csrr r7, 0x64A
    srli r10, r7, 25
    li r11, 0x38
    cmp r10, r11
    bge h_tx
    li r6, 0x10000004
    lbu r12, [r6, 0]
    li r6, 0x1D
    cmp r12, r6
    beq m_detach
    srli r8, r7, 21
    andi r8, r8, 0xF
    slli r9, r8, 2
    add r9, r1, r9
    sw r12, [r9, 0]
    bra h_adv
h_tx:
    srli r8, r7, 21
    andi r8, r8, 0xF
    slli r9, r8, 2
    add r9, r1, r9
    lw r12, [r9, 0]
    li r13, 0x10000000
    sb r12, [r13, 0]
    bra h_adv
m_detach:
    li r1, detached
    call puts
    bra manager

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

h_enter:
    li r2, 0x500
    lw r1, [r2, 0]
    slli r3, r1, 1
    addi r3, r3, 16
    li r4, 0x80000000
    or r3, r3, r4
    csrw 0x680, r3
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
    lw r7, [r6, 92]
    csrw 0x180, r7
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

.rodata
banner_hv: .asciz "\ntb32hv manager online\n"
bye: .asciz "\nbye\n"
prompt: .asciz "\ntb32hv> (l=list c=create k=kill N N=attach q=quit) "
novm: .asciz "no such vm\n"
full: .asciz "no free slot\n"
created: .asciz "created\n"
killed: .asciz "killed\n"
attach: .asciz "\n[attached, ctrl-] to detach]\n"
vmexit: .asciz "\n[vm exited]\n"
detached: .asciz "\n[detached]\n"
lst0: .asciz "vm0="
lst1: .asciz " vm1="
sact: .asciz "active"
sfree: .asciz "free"
nl: .asciz "\n"
