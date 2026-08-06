#include "tbcsr.h"

// Guest-physical address of the console TX register, read from BootInfo at boot.
int g_con_tx;

// Trap frame the assembly entry fills before calling handle_trap: r1..r15 at word
// indices 0..14, then the saved sepc and condition flags. The full register set and
// flags MUST round-trip a trap, or the interrupted user context is corrupted.
int tf[20];

void con_putc(int ch) {
    char* tx;
    tx = (char*)g_con_tx;
    tx[0] = ch;
}

void con_puts(char* s) {
    int i;
    i = 0;
    while (s[i]) { con_putc(s[i]); i = i + 1; }
}

int sys_write(int fd, int buf, int n) {
    char* p;
    int i;
    p = (char*)buf;
    i = 0;
    while (i < n) { con_putc(p[i]); i = i + 1; }
    return n;
}

// Hypercall to the hypervisor: from VS, a `sys` is delivered to the HV (ECALL_VS,
// cause 10), which dispatches on the number in r7. HV number 0 = exit the VM.
void hypercall(int num) {
    __sys(num, 0, 0, 0);
}

int do_syscall(int num, int a, int b, int c) {
    if (num == 1) return sys_write(a, b, c);
    if (num == 11) { hypercall(0); return 0; }
    return 0 - 1;
}

// Called from the assembly trap entry with the user's registers already saved in tf.
void handle_trap() {
    int cause;
    cause = __csrr(CSR_SCAUSE);
    if (cause == CAUSE_ECALL_U) {
        tf[0] = do_syscall(tf[6], tf[0], tf[1], tf[2]);
        return;
    }
    con_puts("kernel: unexpected trap\n");
    hypercall(0);
}

// The first user process: runs in VU and reaches the kernel only through ecall.
void user_main() {
    char* m;
    int n;
    m = "userland -> kernel via ecall\n";
    n = 0;
    while (m[n]) n = n + 1;
    __sys(1, 1, m, n);
    __sys(11, 0, 0, 0);
}

void enter_user(int entry);

void kmain() {
    int* bi;
    bi = (int*)0;
    g_con_tx = bi[5];
    con_puts("kernel: booting in VS mode\n");
    con_puts("kernel: entering userland (VU)\n");
    enter_user(user_main);
}
