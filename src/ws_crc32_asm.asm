; ws_crc32_asm.asm — CRC-32C using PCLMULQDQ parallel folding + SSE4.2 fallback
;
; C signature:
;   uint32_t ws_crc32(const uint8_t *buf, size_t len, uint32_t init);
;
; Usage convention (CRC-32C / Castagnoli):
;   First call:  init = 0xFFFFFFFF
;   Final value: result XOR 0xFFFFFFFF
;   Chaining:    pass previous return value as init for next call
;
; Register map (System V AMD64 ABI):
;   rdi = buf pointer
;   rsi = len
;   edx = init (32-bit accumulator)
;   eax = return value (updated accumulator, NOT yet XOR'd)
;
; Dispatch:
;   len >= 256 && PCLMULQDQ available  →  4-way PCLMULQDQ folding path
;   otherwise                          →  serial CRC32 instruction path
;
; PCLMULQDQ folding algorithm:
;   Process 64 bytes/iteration with 4 independent 128-bit accumulators.
;   Fold constants are reflect33(x^N mod P) where P = 0x11EDC6F41 (CRC-32C).
;   Final reduction: 128→96→64 bits via PCLMULQDQ, then Barrett reduction
;   to 32 bits. Any tail bytes (< 16) handled by serial CRC32 instruction.
;
; Constants derived from CRC-32C polynomial 0x11EDC6F41 (Castagnoli):
;   k1 = reflect33(x^544 mod P) = 0x0740EEF02   (fold-by-4, imm8=0x00: lo*k1)
;   k2 = reflect33(x^480 mod P) = 0x09E4ADDF8   (fold-by-4, imm8=0x11: hi*k2)
;   k3 = reflect33(x^160 mod P) = 0x0F20C0DFE   (fold-by-1, imm8=0x00: lo*k3)
;   k4 = reflect33(x^96  mod P) = 0x14CD00BD6   (fold-by-1, imm8=0x11: hi*k4;
;                                                  also 128→96: imm8=0x10: lo*k4)
;   k5 = reflect33(x^64  mod P) = 0x0DD45AAB8   (96→64 reduction)
;   mu = reflect33(x^64 / P)    = 0x0DEA713F1   (Barrett quotient)
;   Pr = reflect33(P)           = 0x105EC76F1   (Barrett polynomial)
;
; PCLMULQDQ imm8 encoding:
;   0x00 = src1[63:0]   * src2[63:0]    (lo * lo)
;   0x01 = src1[127:64] * src2[63:0]    (hi * lo)
;   0x10 = src1[63:0]   * src2[127:64]  (lo * hi)
;   0x11 = src1[127:64] * src2[127:64]  (hi * hi)

BITS 64
DEFAULT REL

extern cpu_features

section .text

global ws_crc32

; ============================================================================
; ws_crc32(const uint8_t *buf, size_t len, uint32_t init) -> uint32_t
; ============================================================================
ws_crc32:
    mov eax, edx                ; accumulator = init
    test rsi, rsi
    jz  .done

    ; Try PCLMULQDQ path for large buffers
    cmp rsi, 256
    jb  .serial_path
    test dword [cpu_features], (1 << 1)   ; bit 1 = PCLMULQDQ
    jz  .serial_path

    ; === PCLMULQDQ 4-way folding path ===
    ;
    ; Load first 64 bytes into 4 accumulators (xmm0–xmm3).
    ; XOR the init value into the low 32 bits of the first accumulator.
    movdqu xmm4, [rdi]              ; load first 16 bytes (may be unaligned)
    movd xmm0, eax
    pxor xmm0, xmm4                ; acc0 = first 16 bytes XOR init
    movdqu xmm1, [rdi + 16]        ; acc1
    movdqu xmm2, [rdi + 32]        ; acc2
    movdqu xmm3, [rdi + 48]        ; acc3
    add rdi, 64
    sub rsi, 64

    ; Load fold-by-4 constants: k1 (lo) and k2 (hi)
    movdqa xmm8, [k1k2]

    ; --- Main loop: fold 64 bytes per iteration ---
    cmp rsi, 64
    jb  .reduce_4_to_1

    align 16
.fold4_loop:
    ; Load 4 new 16-byte blocks
    movdqu xmm4, [rdi]
    movdqu xmm5, [rdi + 16]
    movdqu xmm6, [rdi + 32]
    movdqu xmm7, [rdi + 48]

    ; Fold accumulator 0: acc0' = clmul(acc0_lo, k1) XOR clmul(acc0_hi, k2) XOR new0
    movdqa xmm9, xmm0
    pclmulqdq xmm0, xmm8, 0x00     ; acc0_lo * k1
    pclmulqdq xmm9, xmm8, 0x11     ; acc0_hi * k2
    pxor xmm0, xmm9
    pxor xmm0, xmm4

    ; Fold accumulator 1
    movdqa xmm9, xmm1
    pclmulqdq xmm1, xmm8, 0x00
    pclmulqdq xmm9, xmm8, 0x11
    pxor xmm1, xmm9
    pxor xmm1, xmm5

    ; Fold accumulator 2
    movdqa xmm9, xmm2
    pclmulqdq xmm2, xmm8, 0x00
    pclmulqdq xmm9, xmm8, 0x11
    pxor xmm2, xmm9
    pxor xmm2, xmm6

    ; Fold accumulator 3
    movdqa xmm9, xmm3
    pclmulqdq xmm3, xmm8, 0x00
    pclmulqdq xmm9, xmm8, 0x11
    pxor xmm3, xmm9
    pxor xmm3, xmm7

    add rdi, 64
    sub rsi, 64
    cmp rsi, 64
    jae .fold4_loop

.reduce_4_to_1:
    ; --- Reduce 4 accumulators to 1 using fold-by-1 constants ---
    movdqa xmm8, [k3k4]

    ; Fold acc1 into acc0
    movdqa xmm4, xmm0
    pclmulqdq xmm0, xmm8, 0x00     ; acc0_lo * k3
    pclmulqdq xmm4, xmm8, 0x11     ; acc0_hi * k4
    pxor xmm0, xmm4
    pxor xmm0, xmm1

    ; Fold acc2 into acc0
    movdqa xmm4, xmm0
    pclmulqdq xmm0, xmm8, 0x00
    pclmulqdq xmm4, xmm8, 0x11
    pxor xmm0, xmm4
    pxor xmm0, xmm2

    ; Fold acc3 into acc0
    movdqa xmm4, xmm0
    pclmulqdq xmm0, xmm8, 0x00
    pclmulqdq xmm4, xmm8, 0x11
    pxor xmm0, xmm4
    pxor xmm0, xmm3

    ; --- Fold remaining 16-byte blocks ---
.fold1_loop:
    cmp rsi, 16
    jb  .final_reduction

    movdqu xmm4, [rdi]
    movdqa xmm5, xmm0
    pclmulqdq xmm0, xmm8, 0x00     ; acc_lo * k3
    pclmulqdq xmm5, xmm8, 0x11     ; acc_hi * k4
    pxor xmm0, xmm5
    pxor xmm0, xmm4

    add rdi, 16
    sub rsi, 16
    jmp .fold1_loop

.final_reduction:
    ; --- 128-bit → 64-bit reduction ---
    ;
    ; xmm0 = [lo64 : hi64]   (128-bit accumulator)
    ; xmm8 = k3k4 (still loaded from fold-by-1 phase)
    ;
    ; Step 1: 128→96 bits
    ;   PCLMULQDQ imm8=0x10: src1[63:0] * src2[127:64] = acc_lo * k4
    ;   Then shift acc right 8 bytes (hi64 moves to lo position) and XOR.
    movdqa xmm1, xmm0
    pclmulqdq xmm0, xmm8, 0x10     ; acc_lo * k4 → ≤96-bit result
    psrldq xmm1, 8                  ; xmm1 = [hi64, 0]
    pxor xmm0, xmm1                 ; 96-bit intermediate in xmm0

    ; Step 2: 96→64 bits
    ;   Multiply low 32 bits by k5 (x^64 mod P), XOR with upper 64 bits.
    movdqa xmm4, [mask32]           ; 32-bit mask (reused in Barrett)
    movdqa xmm1, xmm0
    pand xmm0, xmm4                 ; isolate low 32 bits
    pclmulqdq xmm0, [k5k0], 0x00   ; low32 * k5 → 64-bit result
    psrldq xmm1, 4                  ; shift right by 4 bytes
    pxor xmm0, xmm1                 ; 64-bit CRC residual

    ; --- Barrett reduction: 64-bit → 32-bit ---
    ;
    ; Given 64-bit value V in xmm0[63:0]:
    ;   T = clmul(V[31:0], mu)       → quotient estimate
    ;   R = clmul(T[31:0], P)        → remainder
    ;   CRC = (V XOR R)[63:32]       → final 32-bit CRC
    ;
    ; mu_poly = [P_reflected (lo64), mu (hi64)]
    ; PCLMULQDQ 0x10: src1_lo * src2_hi → V_lo32 * mu
    ; PCLMULQDQ 0x00: src1_lo * src2_lo → T_lo32 * P
    movdqa xmm1, xmm0
    movdqa xmm2, [mu_poly]
    pand xmm0, xmm4                 ; V[31:0]
    pclmulqdq xmm0, xmm2, 0x10     ; V[31:0] * mu
    pand xmm0, xmm4                 ; T[31:0]
    pclmulqdq xmm0, xmm2, 0x00     ; T[31:0] * P
    pxor xmm0, xmm1                 ; V XOR R
    pextrd eax, xmm0, 1            ; extract bits [63:32] = final CRC

    ; Handle remaining tail bytes (< 16) with serial CRC32
    test rsi, rsi
    jz  .done

    ; Fall through to byte-at-a-time tail
    jmp .byte_tail

    ; === Serial CRC32 instruction path (small buffers / no PCLMULQDQ) ===
.serial_path:
    mov rcx, rsi
    shr rcx, 3                      ; rcx = number of 8-byte chunks
    test rcx, rcx
    jz  .serial_tail

    align 16
.qword_loop:
    crc32 rax, qword [rdi]
    add   rdi, 8
    dec   rcx
    jnz   .qword_loop

.serial_tail:
    and   rsi, 7
    jz    .done

.byte_tail:
    align 8
.byte_loop:
    crc32 eax, byte [rdi]
    inc   rdi
    dec   rsi
    jnz   .byte_loop

.done:
    ret

; ============================================================================
; Read-only data — PCLMULQDQ folding constants for CRC-32C (Castagnoli)
;
; Polynomial: P(x) = 0x11EDC6F41 (CRC-32C, iSCSI)
; All folding constants are reflect33(x^N mod P) for reflected-CRC computation.
; Derivation: compute x^N mod P in GF(2) using the normal polynomial,
;             then bit-reverse the 33-bit result.
; ============================================================================
section .data

    ; Fold-by-4 constants (4 independent accumulators, 64 bytes/iter)
    ; k1 = reflect33(x^544 mod P), k2 = reflect33(x^480 mod P)
    ; Used with imm8=0x00 (lo*k1) and imm8=0x11 (hi*k2)
    align 16
    k1k2:   dq 0x00000000740eef02, 0x000000009e4addf8

    ; Fold-by-1 constants (single accumulator reduction, 16 bytes/step)
    ; k3 = reflect33(x^160 mod P), k4 = reflect33(x^96 mod P)
    align 16
    k3k4:   dq 0x00000000f20c0dfe, 0x000000014cd00bd6

    ; 128→64 bit reduction constant
    ; k5 = reflect33(x^64 mod P), padded with zero high qword
    align 16
    k5k0:   dq 0x00000000dd45aab8, 0x0000000000000000

    ; Barrett reduction: [P_reflected, mu]
    ; Pr = reflect33(P) = 0x105EC76F1,  mu = reflect33(x^64 / P) = 0x0DEA713F1
    align 16
    mu_poly: dq 0x00000001_05ec76f1, 0x00000000_dea713f1

    ; 32-bit mask: low 32 bits set, high 96 bits clear
    align 16
    mask32: dd 0xFFFFFFFF, 0, 0, 0

section .note.GNU-stack noalloc noexec nowrite progbits
