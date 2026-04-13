; ============================================================================
; ws_mask_asm.asm — WebSocket Masking/Unmasking + Header Search
;
; Implements:
;   1. ws_mask / ws_unmask — AVX-512 + opmask tail (zero branches)
;                            NT-store path for payloads >= 256KB
;   2. ws_find_header     — PCMPISTRI substring search (SSE4.2)
;
; Key instructions utilized:
;   VPBROADCASTD r8d     — GPR→ZMM broadcast (AVX-512F)
;   VPXORD zmm           — integer-domain XOR (AVX-512F)
;   vmovdqu8 {k1}        — opmask masked load/store (AVX-512BW)
;   BZHI rax, rax, rcx   — build tail opmask: lower rcx bits=1, upper=0 (BMI2)
;                          naturally handles rcx=64 (all-ones) with no branch
;   KMOVQ k1, rax        — load opmask from GPR (AVX-512BW)
;   PCMPISTRI xmm, m, im — string comparison (SSE4.2)
;   PREFETCHT0           — temporal prefetch into all cache levels (cached path)
;   PREFETCHNTA          — non-temporal prefetch (NT-store path only)
;   VMOVNTDQ             — non-temporal store (cache-bypass)
;   REP MOVSB            — fast memcpy (ERMS/FSRM)
;
; Build:
;   nasm -f elf64 ws_mask_asm.asm -o ws_mask_asm.o
; ============================================================================

BITS 64
DEFAULT REL

extern cpu_tier
extern cpu_features
extern nt_threshold

; Skip vzeroupper on AMD (no SSE/AVX transition penalty on Zen).
; On Intel the branch falls through to vzeroupper as normal.
%macro SAFE_VZEROUPPER 0
    test dword [cpu_features], (1 << 5)
    jnz %%skip
    vzeroupper
%%skip:
%endmacro

section .text

; ============================================================================
; ws_mask(source, mask_ptr, output, offset, length)
;
; rdi=src  rsi=mask_ptr  rdx=output  rcx=offset  r8=length
;
; AVX-512 path uses opmask for branchless tail — the entire function
; has ZERO conditional branches in the tail path.
; ============================================================================
global ws_mask
ws_mask:
    add rdx, rcx               ; rdx = dest
    mov rcx, r8                ; rcx = length
    test rcx, rcx
    jz .m_ret

    mov r8d, [rsi]              ; 4-byte mask

    ; ==================== GPR FAST PATH (< 128 bytes) ====================
    ; Avoids SIMD setup overhead for small WebSocket frames (control, etc.)
    cmp rcx, 128
    jae .m_dispatch_simd

    mov r9, r8                  ; build 8-byte mask: r9 = r8d | (r8d << 32)
    shl r9, 32
    or  r9, r8

    mov rax, rcx
    shr rax, 3                  ; 8-byte chunks
    test rax, rax
    jz .m_scalar

.m_gpr8:
    mov r10, [rdi]
    xor r10, r9
    mov [rdx], r10
    add rdi, 8
    add rdx, 8
    dec rax
    jnz .m_gpr8

    and rcx, 7
    jz .m_ret
    jmp .m_scalar

.m_dispatch_simd:
    cmp dword [cpu_tier], 3
    je .m_avx512
    cmp dword [cpu_tier], 2
    je .m_avx2
    jmp .m_sse2

    ; ==================== AVX-512 + OPMASK TAIL ====================
    align 32
.m_avx512:
    vpbroadcastd zmm0, r8d

    cmp rcx, [nt_threshold]     ; >= NT threshold → NT path
    jae .m_nt512

    ; 8x unrolled: 512 bytes/iter
    mov rax, rcx
    shr rax, 9
    test rax, rax
    jz .m_512_tail

    align 32
.m_512_512:
    prefetcht0 [rdi + 2048]
    vmovdqu64 zmm1, [rdi]
    vmovdqu64 zmm2, [rdi + 64]
    vmovdqu64 zmm3, [rdi + 128]
    vmovdqu64 zmm4, [rdi + 192]
    vmovdqu64 zmm5, [rdi + 256]
    vmovdqu64 zmm6, [rdi + 320]
    vmovdqu64 zmm7, [rdi + 384]
    vmovdqu64 zmm8, [rdi + 448]
    vpxord zmm1, zmm1, zmm0
    vpxord zmm2, zmm2, zmm0
    vpxord zmm3, zmm3, zmm0
    vpxord zmm4, zmm4, zmm0
    vpxord zmm5, zmm5, zmm0
    vpxord zmm6, zmm6, zmm0
    vpxord zmm7, zmm7, zmm0
    vpxord zmm8, zmm8, zmm0
    vmovdqu64 [rdx], zmm1
    vmovdqu64 [rdx + 64], zmm2
    vmovdqu64 [rdx + 128], zmm3
    vmovdqu64 [rdx + 192], zmm4
    vmovdqu64 [rdx + 256], zmm5
    vmovdqu64 [rdx + 320], zmm6
    vmovdqu64 [rdx + 384], zmm7
    vmovdqu64 [rdx + 448], zmm8
    add rdi, 512
    add rdx, 512
    dec rax
    jnz .m_512_512

    and rcx, 511

.m_512_tail:
    ; Handle remaining 0-511 bytes — full 64-byte chunks, then opmask tail
    test rcx, rcx
    jz .m_512_done

    mov rax, rcx
    shr rax, 6                  ; full 64-byte chunks (0-7)
    jz .m_512_final

.m_512_full64:
    vmovdqu64 zmm1, [rdi]
    vpxord zmm1, zmm1, zmm0
    vmovdqu64 [rdx], zmm1
    add rdi, 64
    add rdx, 64
    sub rcx, 64
    dec rax
    jnz .m_512_full64

    ; ---- OPMASK TAIL: process exactly rcx remaining bytes (0-63) ----
    ; BZHI with rcx=0 → mask=0 → vmovdqu8{k1=0} is a safe no-op
.m_512_final:
    mov rax, -1
    bzhi rax, rax, rcx
    kmovq k1, rax

    vmovdqu8 zmm1{k1}{z}, [rdi]
    vpxord zmm1, zmm1, zmm0
    vmovdqu8 [rdx]{k1}, zmm1

.m_512_done:
    SAFE_VZEROUPPER
    ret


    ; ==================== AVX-512 NT-STORE PATH (>= 256KB) ====================
    align 32
.m_nt512:
    ; Align destination (rdx) to 64-byte boundary using regular stores
    mov rax, rdx
    neg rax
    and rax, 63                 ; bytes to next 64-byte boundary: (-rdx) & 63
    jz  .m_nt512_aligned

.m_nt512_prologue:
    mov r9b, [rdi]
    xor r9b, r8b
    mov [rdx], r9b
    ror r8d, 8                  ; advance to next mask byte
    inc rdi
    inc rdx
    sub rcx, 1
    sub rax, 1
    jnz .m_nt512_prologue
    vpbroadcastd zmm0, r8d      ; re-sync vector mask to current phase

.m_nt512_aligned:
    mov rax, rcx
    shr rax, 8                  ; 256-byte chunks
    test rax, rax
    jz  .m_nt512_tail

    align 32
.m_nt512_loop:
    prefetchnta [rdi + 1024]
    vmovdqu64 zmm1, [rdi]
    vmovdqu64 zmm2, [rdi + 64]
    vmovdqu64 zmm3, [rdi + 128]
    vmovdqu64 zmm4, [rdi + 192]
    vpxord zmm1, zmm1, zmm0
    vpxord zmm2, zmm2, zmm0
    vpxord zmm3, zmm3, zmm0
    vpxord zmm4, zmm4, zmm0
    vmovntdq [rdx],       zmm1
    vmovntdq [rdx + 64],  zmm2
    vmovntdq [rdx + 128], zmm3
    vmovntdq [rdx + 192], zmm4
    add rdi, 256
    add rdx, 256
    dec rax
    jnz .m_nt512_loop

    and rcx, 255

.m_nt512_tail:
    sfence
    jmp .m_512_tail             ; handle remainder with existing opmask path


    ; ==================== AVX2 (unchanged from v3) ====================
    align 32
.m_avx2:
    vmovd xmm0, r8d
    vpbroadcastd ymm0, xmm0

    cmp rcx, [nt_threshold]     ; >= NT threshold → NT path
    jae .m_nt_avx2

    mov rax, rcx
    shr rax, 7
    test rax, rax
    jz .m_avx2_t32

    align 32
.m_avx2_128:
    prefetcht0 [rdi + 512]
    vmovdqu ymm1, [rdi]
    vmovdqu ymm2, [rdi + 32]
    vmovdqu ymm3, [rdi + 64]
    vmovdqu ymm4, [rdi + 96]
    vpxor ymm1, ymm1, ymm0
    vpxor ymm2, ymm2, ymm0
    vpxor ymm3, ymm3, ymm0
    vpxor ymm4, ymm4, ymm0
    vmovdqu [rdx], ymm1
    vmovdqu [rdx + 32], ymm2
    vmovdqu [rdx + 64], ymm3
    vmovdqu [rdx + 96], ymm4
    add rdi, 128
    add rdx, 128
    dec rax
    jnz .m_avx2_128

    and rcx, 127
    jz .m_avx2_done

.m_avx2_t32:
    mov rax, rcx
    shr rax, 5
    test rax, rax
    jz .m_avx2_t_scalar

.m_avx2_32:
    vmovdqu ymm1, [rdi]
    vpxor ymm1, ymm1, ymm0
    vmovdqu [rdx], ymm1
    add rdi, 32
    add rdx, 32
    dec rax
    jnz .m_avx2_32
    and rcx, 31
    jz .m_avx2_done

.m_avx2_t_scalar:
    SAFE_VZEROUPPER
    jmp .m_scalar

.m_avx2_done:
    SAFE_VZEROUPPER
    ret


    ; ==================== AVX2 NT-STORE PATH (>= 256KB) ====================
    align 32
.m_nt_avx2:
    ; Align destination to 32-byte boundary
    mov rax, rdx
    neg rax
    and rax, 31                 ; bytes to next 32-byte boundary: (-rdx) & 31
    jz  .m_nt_avx2_aligned

.m_nt_avx2_prologue:
    mov r9b, [rdi]
    xor r9b, r8b
    mov [rdx], r9b
    ror r8d, 8                  ; advance to next mask byte
    inc rdi
    inc rdx
    sub rcx, 1
    sub rax, 1
    jnz .m_nt_avx2_prologue
    vmovd xmm0, r8d
    vpbroadcastd ymm0, xmm0     ; re-sync vector mask to current phase

.m_nt_avx2_aligned:
    mov rax, rcx
    shr rax, 7                  ; 128-byte chunks
    test rax, rax
    jz  .m_nt_avx2_tail

    align 32
.m_nt_avx2_loop:
    prefetchnta [rdi + 512]
    vmovdqu ymm1, [rdi]
    vmovdqu ymm2, [rdi + 32]
    vmovdqu ymm3, [rdi + 64]
    vmovdqu ymm4, [rdi + 96]
    vpxor ymm1, ymm1, ymm0
    vpxor ymm2, ymm2, ymm0
    vpxor ymm3, ymm3, ymm0
    vpxor ymm4, ymm4, ymm0
    vmovntdq [rdx],      ymm1
    vmovntdq [rdx + 32], ymm2
    vmovntdq [rdx + 64], ymm3
    vmovntdq [rdx + 96], ymm4
    add rdi, 128
    add rdx, 128
    dec rax
    jnz .m_nt_avx2_loop

    and rcx, 127

.m_nt_avx2_tail:
    SAFE_VZEROUPPER
    sfence
    jmp .m_avx2_t32             ; handle remainder with existing path


    ; ==================== SSE2 ====================
    align 32
.m_sse2:
    movd xmm0, r8d
    pshufd xmm0, xmm0, 0

    mov rax, rcx
    shr rax, 6
    test rax, rax
    jz .m_sse2_t16

    align 16
.m_sse2_64:
    prefetcht0 [rdi + 256]
    movdqu xmm1, [rdi]
    movdqu xmm2, [rdi + 16]
    movdqu xmm3, [rdi + 32]
    movdqu xmm4, [rdi + 48]
    pxor xmm1, xmm0
    pxor xmm2, xmm0
    pxor xmm3, xmm0
    pxor xmm4, xmm0
    movdqu [rdx], xmm1
    movdqu [rdx + 16], xmm2
    movdqu [rdx + 32], xmm3
    movdqu [rdx + 48], xmm4
    add rdi, 64
    add rdx, 64
    dec rax
    jnz .m_sse2_64
    and rcx, 63
    jz .m_ret

.m_sse2_t16:
    mov rax, rcx
    shr rax, 4
    test rax, rax
    jz .m_scalar

.m_sse2_16:
    movdqu xmm1, [rdi]
    pxor xmm1, xmm0
    movdqu [rdx], xmm1
    add rdi, 16
    add rdx, 16
    dec rax
    jnz .m_sse2_16
    and rcx, 15
    jz .m_ret

    ; ==================== SCALAR TAIL (SSE2/AVX2 only) ====================
    align 16
.m_scalar:
    mov rax, rcx
    shr rax, 2
    test rax, rax
    jz .m_bytes
.m_dword:
    mov r9d, [rdi]
    xor r9d, r8d
    mov [rdx], r9d
    add rdi, 4
    add rdx, 4
    dec rax
    jnz .m_dword
    and rcx, 3
    jz .m_ret
.m_bytes:
    mov al, [rdi]
    xor al, r8b
    mov [rdx], al
    dec rcx
    jz .m_ret
    mov al, [rdi + 1]
    xor al, byte [rsi + 1]
    mov [rdx + 1], al
    dec rcx
    jz .m_ret
    mov al, [rdi + 2]
    xor al, byte [rsi + 2]
    mov [rdx + 2], al
.m_ret:
    ret


; ============================================================================
; ws_unmask(buffer, mask_ptr, length) — in-place, with opmask tail
; ============================================================================
global ws_unmask
ws_unmask:
    mov rcx, rdx
    test rcx, rcx
    jz .u_ret

    mov r8d, [rsi]

    ; ==================== GPR FAST PATH (< 128 bytes) ====================
    cmp rcx, 128
    jae .u_dispatch_simd

    mov r9, r8
    shl r9, 32
    or  r9, r8

    mov rax, rcx
    shr rax, 3
    test rax, rax
    jz .u_scalar

.u_gpr8:
    mov r10, [rdi]
    xor r10, r9
    mov [rdi], r10
    add rdi, 8
    dec rax
    jnz .u_gpr8

    and rcx, 7
    jz .u_ret
    jmp .u_scalar

.u_dispatch_simd:
    cmp dword [cpu_tier], 3
    je .u_avx512
    cmp dword [cpu_tier], 2
    je .u_avx2
    jmp .u_sse2

    ; ==================== AVX-512 UNMASK + OPMASK TAIL ====================
    align 32
.u_avx512:
    vpbroadcastd zmm0, r8d

    cmp rcx, [nt_threshold]     ; >= NT threshold → NT path
    jae .u_nt512

    ; Dual-stream: process 256 bytes from front + 256 from back per iteration.
    ; Two independent memory streams increase page-level parallelism and
    ; TLB coverage for large in-place buffers.
    mov rax, rcx
    shr rax, 9                  ; iterations = len / 512
    test rax, rax
    jz .u_512_tail

    lea r11, [rdi + rcx - 256]  ; r11 = back pointer (last 256-byte block)

    align 32
.u_dual_512:
    prefetcht0 [rdi + 1024]
    prefetcht0 [r11 - 768]
    ; Front 256 bytes
    vmovdqu64 zmm1, [rdi]
    vmovdqu64 zmm2, [rdi + 64]
    vmovdqu64 zmm3, [rdi + 128]
    vmovdqu64 zmm4, [rdi + 192]
    ; Back 256 bytes
    vmovdqu64 zmm5, [r11]
    vmovdqu64 zmm6, [r11 + 64]
    vmovdqu64 zmm7, [r11 + 128]
    vmovdqu64 zmm8, [r11 + 192]
    vpxord zmm1, zmm1, zmm0
    vpxord zmm2, zmm2, zmm0
    vpxord zmm3, zmm3, zmm0
    vpxord zmm4, zmm4, zmm0
    vpxord zmm5, zmm5, zmm0
    vpxord zmm6, zmm6, zmm0
    vpxord zmm7, zmm7, zmm0
    vpxord zmm8, zmm8, zmm0
    vmovdqu64 [rdi], zmm1
    vmovdqu64 [rdi + 64], zmm2
    vmovdqu64 [rdi + 128], zmm3
    vmovdqu64 [rdi + 192], zmm4
    vmovdqu64 [r11], zmm5
    vmovdqu64 [r11 + 64], zmm6
    vmovdqu64 [r11 + 128], zmm7
    vmovdqu64 [r11 + 192], zmm8
    add rdi, 256
    sub r11, 256
    dec rax
    jnz .u_dual_512

    ; Remaining middle bytes: (r11 + 256) - rdi
    lea rcx, [r11 + 256]
    sub rcx, rdi

.u_512_tail:
    ; Handle remaining 0-511 bytes — full 64-byte chunks, then opmask tail
    test rcx, rcx
    jz .u_512_done

    mov rax, rcx
    shr rax, 6                  ; full 64-byte chunks (0-7)
    jz .u_512_final

.u_512_full64:
    vmovdqu64 zmm1, [rdi]
    vpxord zmm1, zmm1, zmm0
    vmovdqu64 [rdi], zmm1
    add rdi, 64
    sub rcx, 64
    dec rax
    jnz .u_512_full64

    ; ---- OPMASK TAIL (in-place): rcx remaining bytes (0-63) ----
    ; BZHI with rcx=0 → mask=0 → vmovdqu8{k1=0} is a safe no-op
.u_512_final:
    mov rax, -1
    bzhi rax, rax, rcx
    kmovq k1, rax

    vmovdqu8 zmm1{k1}{z}, [rdi]
    vpxord zmm1, zmm1, zmm0
    vmovdqu8 [rdi]{k1}, zmm1

.u_512_done:
    SAFE_VZEROUPPER
    ret


    ; ==================== AVX-512 UNMASK NT PATH ====================
    align 32
.u_nt512:
    mov rax, rdi
    neg rax
    and rax, 63                 ; bytes to next 64-byte boundary: (-rdi) & 63
    jz  .u_nt512_aligned

.u_nt512_prologue:
    xor byte [rdi], r8b
    ror r8d, 8                  ; advance to next mask byte
    inc rdi
    sub rcx, 1
    sub rax, 1
    jnz .u_nt512_prologue
    vpbroadcastd zmm0, r8d      ; re-sync vector mask to current phase

.u_nt512_aligned:
    mov rax, rcx
    shr rax, 8
    test rax, rax
    jz  .u_nt512_tail

    align 32
.u_nt512_loop:
    prefetchnta [rdi + 1024]
    vmovdqu64 zmm1, [rdi]
    vmovdqu64 zmm2, [rdi + 64]
    vmovdqu64 zmm3, [rdi + 128]
    vmovdqu64 zmm4, [rdi + 192]
    vpxord zmm1, zmm1, zmm0
    vpxord zmm2, zmm2, zmm0
    vpxord zmm3, zmm3, zmm0
    vpxord zmm4, zmm4, zmm0
    vmovntdq [rdi],       zmm1
    vmovntdq [rdi + 64],  zmm2
    vmovntdq [rdi + 128], zmm3
    vmovntdq [rdi + 192], zmm4
    add rdi, 256
    dec rax
    jnz .u_nt512_loop

    and rcx, 255

.u_nt512_tail:
    sfence
    jmp .u_512_tail


    ; ==================== AVX2 UNMASK ====================
    align 32
.u_avx2:
    vmovd xmm0, r8d
    vpbroadcastd ymm0, xmm0

    cmp rcx, [nt_threshold]     ; >= NT threshold → NT path
    jae .u_nt_avx2

    mov rax, rcx
    shr rax, 7
    test rax, rax
    jz .u_avx2_t32

    align 32
.u_avx2_128:
    prefetcht0 [rdi + 512]
    vmovdqu ymm1, [rdi]
    vmovdqu ymm2, [rdi + 32]
    vmovdqu ymm3, [rdi + 64]
    vmovdqu ymm4, [rdi + 96]
    vpxor ymm1, ymm1, ymm0
    vpxor ymm2, ymm2, ymm0
    vpxor ymm3, ymm3, ymm0
    vpxor ymm4, ymm4, ymm0
    vmovdqu [rdi], ymm1
    vmovdqu [rdi + 32], ymm2
    vmovdqu [rdi + 64], ymm3
    vmovdqu [rdi + 96], ymm4
    add rdi, 128
    dec rax
    jnz .u_avx2_128
    and rcx, 127
    jz .u_avx2_done

.u_avx2_t32:
    mov rax, rcx
    shr rax, 5
    test rax, rax
    jz .u_avx2_scalar
.u_avx2_32:
    vmovdqu ymm1, [rdi]
    vpxor ymm1, ymm1, ymm0
    vmovdqu [rdi], ymm1
    add rdi, 32
    dec rax
    jnz .u_avx2_32
    and rcx, 31
    jz .u_avx2_done

.u_avx2_scalar:
    SAFE_VZEROUPPER
    jmp .u_scalar

.u_avx2_done:
    SAFE_VZEROUPPER
    ret


    ; ==================== AVX2 UNMASK NT PATH ====================
    align 32
.u_nt_avx2:
    ; Align destination to 32-byte boundary
    mov rax, rdi
    neg rax
    and rax, 31                 ; bytes to next 32-byte boundary: (-rdi) & 31
    jz  .u_nt_avx2_aligned

.u_nt_avx2_prologue:
    xor byte [rdi], r8b
    ror r8d, 8                  ; advance to next mask byte
    inc rdi
    sub rcx, 1
    sub rax, 1
    jnz .u_nt_avx2_prologue
    vmovd xmm0, r8d
    vpbroadcastd ymm0, xmm0     ; re-sync vector mask to current phase

.u_nt_avx2_aligned:
    mov rax, rcx
    shr rax, 7                  ; 128-byte chunks
    test rax, rax
    jz  .u_nt_avx2_tail

    align 32
.u_nt_avx2_loop:
    prefetchnta [rdi + 512]
    vmovdqu ymm1, [rdi]
    vmovdqu ymm2, [rdi + 32]
    vmovdqu ymm3, [rdi + 64]
    vmovdqu ymm4, [rdi + 96]
    vpxor ymm1, ymm1, ymm0
    vpxor ymm2, ymm2, ymm0
    vpxor ymm3, ymm3, ymm0
    vpxor ymm4, ymm4, ymm0
    vmovntdq [rdi],      ymm1
    vmovntdq [rdi + 32], ymm2
    vmovntdq [rdi + 64], ymm3
    vmovntdq [rdi + 96], ymm4
    add rdi, 128
    dec rax
    jnz .u_nt_avx2_loop

    and rcx, 127

.u_nt_avx2_tail:
    SAFE_VZEROUPPER
    sfence
    jmp .u_avx2_t32             ; handle remainder with existing path


    ; ==================== SSE2 UNMASK ====================
    align 32
.u_sse2:
    movd xmm0, r8d
    pshufd xmm0, xmm0, 0

    mov rax, rcx
    shr rax, 6
    test rax, rax
    jz .u_sse2_t16
    align 16
.u_sse2_64:
    prefetcht0 [rdi + 256]
    movdqu xmm1, [rdi]
    movdqu xmm2, [rdi + 16]
    movdqu xmm3, [rdi + 32]
    movdqu xmm4, [rdi + 48]
    pxor xmm1, xmm0
    pxor xmm2, xmm0
    pxor xmm3, xmm0
    pxor xmm4, xmm0
    movdqu [rdi], xmm1
    movdqu [rdi + 16], xmm2
    movdqu [rdi + 32], xmm3
    movdqu [rdi + 48], xmm4
    add rdi, 64
    dec rax
    jnz .u_sse2_64
    and rcx, 63
    jz .u_ret
.u_sse2_t16:
    mov rax, rcx
    shr rax, 4
    test rax, rax
    jz .u_scalar
.u_sse2_16:
    movdqu xmm1, [rdi]
    pxor xmm1, xmm0
    movdqu [rdi], xmm1
    add rdi, 16
    dec rax
    jnz .u_sse2_16
    and rcx, 15
    jz .u_ret

    ; ==================== SCALAR TAIL (unmask) ====================
.u_scalar:
    mov rax, rcx
    shr rax, 2
    test rax, rax
    jz .u_bytes
.u_dword:
    xor dword [rdi], r8d
    add rdi, 4
    dec rax
    jnz .u_dword
    and rcx, 3
    jz .u_ret
.u_bytes:
    xor byte [rdi], r8b
    dec rcx
    jz .u_ret
    mov al, byte [rsi + 1]
    xor byte [rdi + 1], al
    dec rcx
    jz .u_ret
    mov al, byte [rsi + 2]
    xor byte [rdi + 2], al
.u_ret:
    ret


; ============================================================================
; ws_find_header — Find a header value in HTTP request using PCMPISTRI
;
; C: int64_t ws_find_header(const uint8_t *buf, size_t len,
;                           const uint8_t *needle, size_t needle_len);
;
; Returns: offset of value start, or -1 if not found
; Uses SSE4.2 PCMPISTRI for 16-bytes-at-a-time substring matching
;
; rdi=buf  rsi=len  rdx=needle  rcx=needle_len
; ============================================================================
global ws_find_header
ws_find_header:
    push rbx
    push r12
    push r13
    push r14

    mov r12, rdi                ; buf
    mov r13, rsi                ; len
    mov r14, rdx                ; needle
    mov rbx, rcx                ; needle_len

    ; Load first 16 bytes of needle into xmm0
    ; PCMPISTRI uses implicit length (stops at null or register width)
    ; Our needle is "Sec-WebSocket-Key: " (19 bytes) — longer than 16
    ; So we do a two-phase search: find first 16 chars, then verify rest

    movdqu xmm0, [r14]         ; first 16 bytes of needle

    ; r11 = outer scan position (caller-saved — no push/pop needed)
    xor r11, r11

    ; PCMPISTRI mode 0x0C = Equal Ordered (substring match)
    ; Compares bytes in xmm0 against 16 bytes at [buf+r11]
    ; CF=1 if match found; ECX = inner match index (0-15)
    ; CF=0 if no match;    ECX = 16
    ; r11 is kept in a separate register so pcmpistri cannot destroy it
    align 16
.hdr_scan:
    lea rax, [r13]
    sub rax, r11
    cmp rax, 16
    jl .hdr_scalar_tail         ; fewer than 16 bytes left

    pcmpistri xmm0, [r12 + r11], 0x0C
    jnc .hdr_no_match
    ; CF=1: candidate at absolute position r11 + rcx
    lea rax, [r11 + rcx]        ; rax = absolute candidate position

.hdr_verify:
    push rax
    lea rdi, [r12 + rax]
    mov rsi, r14
    mov rcx, rbx
    repe cmpsb
    pop rax
    je .hdr_found               ; full match — rax = needle start

    lea r11, [rax + 1]          ; resume scan past this candidate
    jmp .hdr_scan

.hdr_no_match:
    add r11, 16                 ; advance outer position by full window
    jmp .hdr_scan

.hdr_scalar_tail:
    ; Fewer than 16 bytes remaining — do byte-by-byte
    lea rax, [r13]
    sub rax, rbx                ; rax = max valid start = len - needle_len
.hdr_scalar:
    cmp r11, rax
    jg .hdr_not_found

    push r11
    lea rdi, [r12 + r11]
    mov rsi, r14
    mov rcx, rbx
    repe cmpsb
    pop r11
    je .hdr_found_scalar

    inc r11
    jmp .hdr_scalar

.hdr_found_scalar:
    lea rax, [r11 + rbx]        ; value start = match_pos + needle_len
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.hdr_found:
    ; rax = needle start, rbx = needle_len
    add rax, rbx                ; value start = needle_start + needle_len
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.hdr_not_found:
    mov rax, -1
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; Non-executable stack
section .note.GNU-stack noalloc noexec nowrite progbits
