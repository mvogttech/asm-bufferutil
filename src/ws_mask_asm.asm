; ============================================================================
; ws_mask_asm.asm — WebSocket Masking/Unmasking + Header Search
;
; Implements:
;   1. ws_mask / ws_unmask — AVX-512 + opmask tail (zero branches)
;                            NT-store path for payloads >= 256KB
;   2. ws_find_header     — AVX-512 VPCMPEQB first+last byte filter (64B/iter)
;                            Fallback: SSE4.2 PCMPISTRI (16B/iter)
;
; Key instructions utilized:
;   VPXORD zmm, zmm, m512— memory-operand fused load+XOR (AVX-512F)
;   VPXOR  ymm, ymm, m256— memory-operand fused load+XOR (AVX2)
;   VPBROADCASTD r8d     — GPR→ZMM dword broadcast (AVX-512F)
;   VPBROADCASTB eax     — GPR→ZMM byte broadcast (AVX-512BW)
;   VPCMPEQB k, zmm, zmm— byte compare to opmask (AVX-512BW)
;   KANDQ k, k, k        — AND opmask registers (AVX-512BW)
;   KORTESTQ k, k        — test opmask for any set bits (AVX-512BW)
;   vmovdqu8 {k1}        — opmask masked load/store (AVX-512BW)
;   BZHI rax, rax, rcx   — build tail opmask: lower rcx bits=1, upper=0 (BMI2)
;                          naturally handles rcx=64 (all-ones) with no branch
;   RORX r64, r/m64, imm8— non-destructive rotate (BMI2, ws_mask_gfni GPR path)
;   KMOVQ k1, rax        — load opmask from GPR (AVX-512BW)
;   TZCNT rcx, rax       — count trailing zeros for candidate extraction (BMI1)
;   BLSR rax, rax        — clear lowest set bit for candidate iteration (BMI1)
;   PCMPISTRI xmm, m, im — string comparison (SSE4.2, fallback path)
;   PREFETCHT0           — temporal prefetch into all cache levels (cached path)
;   PREFETCHNTA          — non-temporal prefetch (NT-store path only)
;   VMOVNTDQA            — non-temporal load hint (NT unmask path, rdi aligned)
;   VMOVNTDQ             — non-temporal store (cache-bypass)
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
    ; 4x unrolled (32 bytes/iter) with offset addressing to reduce loop overhead
    cmp rcx, 128
    jae .m_dispatch_simd

    mov r9, r8                  ; build 8-byte mask: r9 = r8d | (r8d << 32)
    shl r9, 32
    or  r9, r8

    ; 4x unrolled: 32 bytes per iteration
    mov rax, rcx
    shr rax, 5                  ; 32-byte chunks
    jz .m_gpr8_rem

    align 16
.m_gpr32:
    mov r10, [rdi]
    mov r11, [rdi + 8]
    xor r10, r9
    xor r11, r9
    mov [rdx], r10
    mov [rdx + 8], r11
    mov r10, [rdi + 16]
    mov r11, [rdi + 24]
    xor r10, r9
    xor r11, r9
    mov [rdx + 16], r10
    mov [rdx + 24], r11
    add rdi, 32
    add rdx, 32
    dec rax
    jnz .m_gpr32

    and rcx, 31

.m_gpr8_rem:
    mov rax, rcx
    shr rax, 3                  ; remaining 8-byte chunks (0-3)
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

    ; Align destination (rdx) to 64-byte boundary using opmask partial store
    mov rax, rdx
    neg rax
    and rax, 63                 ; bytes to next 64-byte boundary
    jz .m_512_aligned
    cmp rax, rcx                ; preamble larger than total payload?
    jae .m_512_tail             ; → skip alignment, do unaligned tail

    mov r9, -1
    bzhi r9, r9, rax
    kmovq k1, r9

    vmovdqu8 zmm1{k1}{z}, [rdi]
    vpxord zmm1, zmm1, zmm0
    vmovdqu8 [rdx]{k1}, zmm1

    add rdi, rax
    add rdx, rax
    sub rcx, rax

    ; Re-sync mask vector if advance was not a multiple of 4
    test al, 3
    jz .m_512_aligned
    mov r9, rcx                 ; save length (need cl for ror)
    mov ecx, eax
    and ecx, 3
    shl ecx, 3                  ; rotation amount in bits
    ror r8d, cl
    mov rcx, r9
    vpbroadcastd zmm0, r8d

.m_512_aligned:
    ; 8x unrolled: 512 bytes/iter (rdx now 64-byte aligned)
    mov rax, rcx
    shr rax, 9
    jz .m_512_tail

    align 32
.m_512_512:
    ; 8x unrolled: memory-operand VPXORD fuses load+XOR into one instruction.
    ; OoO engine (Zen 4: 320-entry ROB) overlaps loads and stores naturally.
    prefetcht0 [rdi + 2048]

    vpxord zmm1, zmm0, [rdi]
    vpxord zmm2, zmm0, [rdi + 64]
    vpxord zmm3, zmm0, [rdi + 128]
    vpxord zmm4, zmm0, [rdi + 192]
    vpxord zmm5, zmm0, [rdi + 256]
    vpxord zmm6, zmm0, [rdi + 320]
    vpxord zmm7, zmm0, [rdi + 384]
    vpxord zmm8, zmm0, [rdi + 448]
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
    vpxord zmm1, zmm0, [rdi]
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
    jz  .m_nt512_tail

    align 32
.m_nt512_loop:
    prefetchnta [rdi + 1024]
    vpxord zmm1, zmm0, [rdi]
    vpxord zmm2, zmm0, [rdi + 64]
    vpxord zmm3, zmm0, [rdi + 128]
    vpxord zmm4, zmm0, [rdi + 192]
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


    ; ==================== AVX2 ====================
    align 32
.m_avx2:
    vmovd xmm0, r8d
    vpbroadcastd ymm0, xmm0

    cmp rcx, [nt_threshold]     ; >= NT threshold → NT path
    jae .m_nt_avx2

    ; Align destination (rdx) to 32-byte boundary
    mov rax, rdx
    neg rax
    and rax, 31                 ; bytes to next 32-byte boundary
    jz .m_avx2_aligned
    cmp rax, rcx
    jae .m_avx2_aligned         ; tiny payload — not worth aligning
    sub rcx, rax

.m_avx2_pre_dw:
    cmp rax, 4
    jb .m_avx2_pre_bytes
    mov r9d, [rdi]
    xor r9d, r8d
    mov [rdx], r9d
    add rdi, 4
    add rdx, 4
    sub rax, 4
    jmp .m_avx2_pre_dw

.m_avx2_pre_bytes:
    test rax, rax
    jz .m_avx2_aligned
.m_avx2_pre_byte:
    mov r9b, [rdi]
    xor r9b, r8b
    mov [rdx], r9b
    ror r8d, 8
    inc rdi
    inc rdx
    dec rax
    jnz .m_avx2_pre_byte
    vmovd xmm0, r8d
    vpbroadcastd ymm0, xmm0    ; re-sync after mask rotation

.m_avx2_aligned:
    mov rax, rcx
    shr rax, 7
    jz .m_avx2_t32

    align 32
.m_avx2_128:
    prefetcht0 [rdi + 512]
    vpxor ymm1, ymm0, [rdi]
    vpxor ymm2, ymm0, [rdi + 32]
    vpxor ymm3, ymm0, [rdi + 64]
    vpxor ymm4, ymm0, [rdi + 96]
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
    jz .m_avx2_t_scalar

.m_avx2_32:
    vpxor ymm1, ymm0, [rdi]
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
    jz  .m_nt_avx2_tail

    align 32
.m_nt_avx2_loop:
    prefetchnta [rdi + 512]
    vpxor ymm1, ymm0, [rdi]
    vpxor ymm2, ymm0, [rdi + 32]
    vpxor ymm3, ymm0, [rdi + 64]
    vpxor ymm4, ymm0, [rdi + 96]
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
    sfence
    jmp .m_avx2_t32             ; ymm0 still holds valid mask; .m_avx2_t32 owns vzeroupper


    ; ==================== SSE2 ====================
    align 32
.m_sse2:
    movd xmm0, r8d
    pshufd xmm0, xmm0, 0

    mov rax, rcx
    shr rax, 6
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
    test rcx, rcx
    jz .m_ret
    mov al, [rdi]
    xor al, r8b
    mov [rdx], al
    dec rcx
    jz .m_ret
    ror r8d, 8
    mov al, [rdi + 1]
    xor al, r8b
    mov [rdx + 1], al
    dec rcx
    jz .m_ret
    ror r8d, 8
    mov al, [rdi + 2]
    xor al, r8b
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
    ; 4x unrolled (32 bytes/iter) with interleaved loads for ILP
    cmp rcx, 128
    jae .u_dispatch_simd

    mov r9, r8
    shl r9, 32
    or  r9, r8

    ; 4x unrolled: 32 bytes per iteration
    mov rax, rcx
    shr rax, 5                  ; 32-byte chunks
    jz .u_gpr8_rem

    align 16
.u_gpr32:
    mov r10, [rdi]
    mov r11, [rdi + 8]
    xor r10, r9
    xor r11, r9
    mov [rdi], r10
    mov [rdi + 8], r11
    mov r10, [rdi + 16]
    mov r11, [rdi + 24]
    xor r10, r9
    xor r11, r9
    mov [rdi + 16], r10
    mov [rdi + 24], r11
    add rdi, 32
    dec rax
    jnz .u_gpr32

    and rcx, 31

.u_gpr8_rem:
    mov rax, rcx
    shr rax, 3                  ; remaining 8-byte chunks (0-3)
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

    ; Align buffer (rdi) to 64-byte boundary using opmask partial store
    mov rax, rdi
    neg rax
    and rax, 63                 ; bytes to next 64-byte boundary
    jz .u_512_aligned
    cmp rax, rcx
    jae .u_512_tail             ; preamble >= total → do unaligned tail

    mov r9, -1
    bzhi r9, r9, rax
    kmovq k1, r9

    vmovdqu8 zmm1{k1}{z}, [rdi]
    vpxord zmm1, zmm1, zmm0
    vmovdqu8 [rdi]{k1}, zmm1

    add rdi, rax
    sub rcx, rax

    ; Re-sync mask vector if advance was not a multiple of 4
    test al, 3
    jz .u_512_aligned
    mov r9, rcx
    mov ecx, eax
    and ecx, 3
    shl ecx, 3
    ror r8d, cl
    mov rcx, r9
    vpbroadcastd zmm0, r8d

.u_512_aligned:
    ; 8x unrolled: 512 bytes/iter (rdi now 64-byte aligned, in-place)
    mov rax, rcx
    shr rax, 9                  ; iterations = len / 512
    jz .u_512_tail

    align 32
.u_512_512:
    ; 8x unrolled: memory-operand VPXORD fuses load+XOR into one instruction.
    ; OoO engine (Zen 4: 320-entry ROB) overlaps loads and stores naturally.
    prefetcht0 [rdi + 2048]

    vpxord zmm1, zmm0, [rdi]
    vpxord zmm2, zmm0, [rdi + 64]
    vpxord zmm3, zmm0, [rdi + 128]
    vpxord zmm4, zmm0, [rdi + 192]
    vpxord zmm5, zmm0, [rdi + 256]
    vpxord zmm6, zmm0, [rdi + 320]
    vpxord zmm7, zmm0, [rdi + 384]
    vpxord zmm8, zmm0, [rdi + 448]
    vmovdqu64 [rdi], zmm1
    vmovdqu64 [rdi + 64], zmm2
    vmovdqu64 [rdi + 128], zmm3
    vmovdqu64 [rdi + 192], zmm4
    vmovdqu64 [rdi + 256], zmm5
    vmovdqu64 [rdi + 320], zmm6
    vmovdqu64 [rdi + 384], zmm7
    vmovdqu64 [rdi + 448], zmm8

    add rdi, 512
    dec rax
    jnz .u_512_512

    and rcx, 511

.u_512_tail:
    ; Handle remaining 0-511 bytes — full 64-byte chunks, then opmask tail
    test rcx, rcx
    jz .u_512_done

    mov rax, rcx
    shr rax, 6                  ; full 64-byte chunks (0-7)
    jz .u_512_final

.u_512_full64:
    vpxord zmm1, zmm0, [rdi]
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
    jz  .u_nt512_tail

    align 32
.u_nt512_loop:
    prefetchnta [rdi + 1024]
    vmovntdqa zmm1, [rdi]          ; NT load (rdi 64-byte aligned by prologue)
    vmovntdqa zmm2, [rdi + 64]
    vmovntdqa zmm3, [rdi + 128]
    vmovntdqa zmm4, [rdi + 192]
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

    ; Align buffer (rdi) to 32-byte boundary
    mov rax, rdi
    neg rax
    and rax, 31
    jz .u_avx2_aligned
    cmp rax, rcx
    jae .u_avx2_aligned         ; tiny payload — not worth aligning
    sub rcx, rax

.u_avx2_pre_dw:
    cmp rax, 4
    jb .u_avx2_pre_bytes
    xor dword [rdi], r8d
    add rdi, 4
    sub rax, 4
    jmp .u_avx2_pre_dw

.u_avx2_pre_bytes:
    test rax, rax
    jz .u_avx2_aligned
.u_avx2_pre_byte:
    xor byte [rdi], r8b
    ror r8d, 8
    inc rdi
    dec rax
    jnz .u_avx2_pre_byte
    vmovd xmm0, r8d
    vpbroadcastd ymm0, xmm0    ; re-sync after mask rotation

.u_avx2_aligned:
    mov rax, rcx
    shr rax, 7
    jz .u_avx2_t32

    align 32
.u_avx2_128:
    prefetcht0 [rdi + 512]
    vpxor ymm1, ymm0, [rdi]
    vpxor ymm2, ymm0, [rdi + 32]
    vpxor ymm3, ymm0, [rdi + 64]
    vpxor ymm4, ymm0, [rdi + 96]
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
    jz .u_avx2_scalar
.u_avx2_32:
    vpxor ymm1, ymm0, [rdi]
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
    jz  .u_nt_avx2_tail

    align 32
.u_nt_avx2_loop:
    prefetchnta [rdi + 512]
    vmovntdqa ymm1, [rdi]          ; NT load (rdi 32-byte aligned by prologue)
    vmovntdqa ymm2, [rdi + 32]
    vmovntdqa ymm3, [rdi + 64]
    vmovntdqa ymm4, [rdi + 96]
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
    sfence
    jmp .u_avx2_t32             ; ymm0 still holds valid mask; .u_avx2_t32 owns vzeroupper


    ; ==================== SSE2 UNMASK ====================
    align 32
.u_sse2:
    movd xmm0, r8d
    pshufd xmm0, xmm0, 0

    mov rax, rcx
    shr rax, 6
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
    jz .u_bytes
.u_dword:
    xor dword [rdi], r8d
    add rdi, 4
    dec rax
    jnz .u_dword
    and rcx, 3
    jz .u_ret
.u_bytes:
    test rcx, rcx
    jz .u_ret
    xor byte [rdi], r8b
    dec rcx
    jz .u_ret
    ror r8d, 8
    xor byte [rdi + 1], r8b
    dec rcx
    jz .u_ret
    ror r8d, 8
    xor byte [rdi + 2], r8b
.u_ret:
    ret


; ============================================================================
; ws_find_header — Find a header value in HTTP request
;
; C: int64_t ws_find_header(const uint8_t *buf, size_t len,
;                           const uint8_t *needle, size_t needle_len);
;
; Returns: offset of value start (match_pos + needle_len), or -1 if not found
;
; Two paths:
;   cpu_tier >= 3 → AVX-512 VPCMPEQB first+last byte filter (64 bytes/iter)
;   otherwise     → SSE4.2 PCMPISTRI fallback (16 bytes/iter)
;
; AVX-512 algorithm (first+last byte filter):
;   1. Broadcast needle[0] into zmm2, needle[needle_len-1] into zmm3
;   2. Load 64 bytes at pos (first-byte block) and pos+needle_len-1 (last-byte)
;   3. VPCMPEQB each block, KANDQ the two masks → candidates with both match
;   4. TZCNT each set bit → candidate; verify middle bytes with repe cmpsb
;   5. Tail (< 64 bytes) handled via BZHI opmask
;
; rdi=buf  rsi=len  rdx=needle  rcx=needle_len
; ============================================================================
global ws_find_header
ws_find_header:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp

    mov r12, rdi                ; buf
    mov r13, rsi                ; len
    mov r14, rdx                ; needle
    mov rbx, rcx                ; needle_len

    ; Quick rejection: needle_len == 0 or needle_len > len
    test rbx, rbx
    jz .hdr_not_found
    cmp rbx, r13
    ja .hdr_not_found

    cmp dword [cpu_tier], 3
    jge .hdr_avx512
    jmp .hdr_pcmpistri

; ────────────────────────────────────────────────────────────────────────────
; AVX-512 path: first+last byte VPCMPEQB filter, 64 bytes per iteration
; ────────────────────────────────────────────────────────────────────────────
.hdr_avx512:
    ; Broadcast needle[0] into zmm2
    movzx eax, byte [r14]
    vpbroadcastb zmm2, eax

    ; Broadcast needle[needle_len-1] into zmm3
    movzx eax, byte [r14 + rbx - 1]
    vpbroadcastb zmm3, eax

    ; r15 = needle_len - 1 (shift amount for last-byte mask)
    lea r15, [rbx - 1]

    ; rbp = max valid start position = len - needle_len
    mov rbp, r13
    sub rbp, rbx

    ; r11 = current scan position
    xor r11, r11

    ; How many full 64-byte blocks can we scan?
    ; We load 64 bytes at pos (first-byte block) and 64 bytes at
    ; pos + needle_len - 1 (last-byte block).  The last-byte block's
    ; final address is pos + (needle_len-1) + 63.  For both loads to
    ; stay in bounds we need:
    ;   pos + (needle_len-1) + 63 <= len - 1
    ;   pos <= len - needle_len - 63  =  rbp - 63
    ; For the tail, we use masked loads.

    ; r8 = rbp - 63  (max pos for unmasked 64-byte loads)
    ; If negative (small buffer), skip straight to tail.
    mov r8, rbp
    sub r8, 63
    jl .hdr_avx512_tail_setup

    align 16
.hdr_avx512_loop:
    cmp r11, r8
    jg .hdr_avx512_tail_setup

    ; Load 64 bytes of haystack at current position
    vmovdqu64 zmm0, [r12 + r11]

    ; Load 64 bytes shifted by (needle_len - 1) for last-byte comparison
    lea r9, [r11 + r15]
    vmovdqu64 zmm1, [r12 + r9]

    ; Compare first byte
    vpcmpeqb k1, zmm0, zmm2

    ; Compare last byte
    vpcmpeqb k2, zmm1, zmm3

    ; AND the two masks: candidates where BOTH first and last byte match
    kandq k3, k1, k2

    ; Any candidates?
    kortestq k3, k3
    jz .hdr_avx512_next

    ; Extract candidate bitmask
    kmovq rax, k3

    ; Process each candidate
.hdr_avx512_candidates:
    tzcnt rcx, rax              ; rcx = bit index of first candidate
    ; Absolute position = r11 + rcx
    lea rdx, [r11 + rcx]

    ; Check: is candidate within valid range?
    cmp rdx, rbp
    ja .hdr_avx512_skip_bit

    ; For needle_len <= 1, first+last byte filter is sufficient (they overlap)
    cmp rbx, 1
    je .hdr_avx512_found_at_rdx

    ; For needle_len == 2, first+last byte filter already confirmed both bytes
    cmp rbx, 2
    je .hdr_avx512_found_at_rdx

    ; Verify full needle with repe cmpsb (skip first and last byte, already checked)
    push rax
    push r11
    lea rdi, [r12 + rdx + 1]   ; buf + candidate + 1 (skip first byte)
    lea rsi, [r14 + 1]         ; needle + 1 (skip first byte)
    mov rcx, rbx
    sub rcx, 2                  ; compare middle bytes (needle_len - 2)
    jz .hdr_avx512_verify_match ; no middle bytes to check (len was 2, handled above, but safety)
    repe cmpsb
    pop r11
    pop rax
    je .hdr_avx512_found_at_rdx

.hdr_avx512_skip_bit:
    blsr rax, rax               ; clear lowest set bit
    jnz .hdr_avx512_candidates  ; more candidates in this block
    jmp .hdr_avx512_next

.hdr_avx512_verify_match:
    ; Middle bytes matched (or there were none)
    pop r11
    pop rax
    ; fall through to found

.hdr_avx512_found_at_rdx:
    ; rdx = match position, return rdx + needle_len
    lea rax, [rdx + rbx]
    SAFE_VZEROUPPER
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.hdr_avx512_next:
    add r11, 64
    jmp .hdr_avx512_loop

; ── AVX-512 tail: fewer than 64 usable bytes remain ──────────────────────
.hdr_avx512_tail_setup:
    ; We need to handle the remaining bytes from r11 to the end of buf.
    ; The first-byte candidates can be from r11..rbp (inclusive).
    ; We need to load from r11..(r11+63) for the first-byte check, but
    ; some of those bytes may be past the buffer end → use opmask.
    ; Similarly for the last-byte load at r11+needle_len-1.
    ;
    ; Number of valid bytes for first-byte load:
    ;   first_count = min(64, len - r11)
    ; Number of valid bytes for last-byte load:
    ;   last_count = min(64, len - r11 - (needle_len - 1))
    ;              = min(64, len - r11 - r15)
    ; But a candidate at offset i (0-based within block) is valid only if
    ;   r11 + i <= rbp, i.e., i <= rbp - r11.

    cmp r11, rbp
    ja .hdr_not_found           ; no more valid start positions

    ; first_count = len - r11 (guaranteed <= 63+needle_len-1 < 128)
    mov rcx, r13
    sub rcx, r11
    cmp rcx, 64
    jbe .hdr_avx512_tail_first_ok
    mov rcx, 64
.hdr_avx512_tail_first_ok:
    ; Build opmask for first-byte load: lower rcx bits set
    mov rax, -1                 ; all ones
    bzhi rax, rax, rcx          ; lower rcx bits = 1
    kmovq k4, rax

    ; Load first-byte block with mask
    vmovdqu8 zmm0{k4}{z}, [r12 + r11]

    ; last_count = len - r11 - r15 = len - r11 - (needle_len - 1)
    mov rcx, r13
    sub rcx, r11
    sub rcx, r15
    jle .hdr_not_found          ; not enough bytes for even one candidate
    cmp rcx, 64
    jbe .hdr_avx512_tail_last_ok
    mov rcx, 64
.hdr_avx512_tail_last_ok:
    mov rax, -1
    bzhi rax, rax, rcx
    kmovq k5, rax

    ; Load last-byte block with mask
    lea r9, [r11 + r15]
    vmovdqu8 zmm1{k5}{z}, [r12 + r9]

    ; Compare first byte
    vpcmpeqb k1, zmm0, zmm2

    ; Compare last byte
    vpcmpeqb k2, zmm1, zmm3

    ; AND the two masks
    kandq k3, k1, k2

    ; Also mask out candidates beyond rbp
    ; valid_count = rbp - r11 + 1
    mov rcx, rbp
    sub rcx, r11
    inc rcx
    cmp rcx, 64
    jge .hdr_avx512_tail_no_trim
    mov rax, -1
    bzhi rax, rax, rcx
    kmovq k6, rax
    kandq k3, k3, k6
.hdr_avx512_tail_no_trim:

    kortestq k3, k3
    jz .hdr_not_found

    kmovq rax, k3

    ; Process tail candidates (same logic as main loop)
.hdr_avx512_tail_candidates:
    tzcnt rcx, rax
    lea rdx, [r11 + rcx]

    cmp rdx, rbp
    ja .hdr_avx512_tail_skip

    cmp rbx, 1
    je .hdr_avx512_found_at_rdx
    cmp rbx, 2
    je .hdr_avx512_found_at_rdx

    ; Verify middle bytes
    push rax
    push r11
    lea rdi, [r12 + rdx + 1]
    lea rsi, [r14 + 1]
    mov rcx, rbx
    sub rcx, 2
    jz .hdr_avx512_tail_verify_match
    repe cmpsb
    pop r11
    pop rax
    je .hdr_avx512_found_at_rdx

.hdr_avx512_tail_skip:
    blsr rax, rax
    jnz .hdr_avx512_tail_candidates
    jmp .hdr_not_found

.hdr_avx512_tail_verify_match:
    pop r11
    pop rax
    jmp .hdr_avx512_found_at_rdx

; ────────────────────────────────────────────────────────────────────────────
; SSE4.2 PCMPISTRI fallback (cpu_tier < 3)
; ────────────────────────────────────────────────────────────────────────────
.hdr_pcmpistri:
    ; Load first 16 bytes of needle into xmm0
    ; PCMPISTRI uses implicit length (stops at null or register width)
    movdqu xmm0, [r14]         ; first 16 bytes of needle

    ; r11 = outer scan position
    xor r11, r11

    ; PCMPISTRI mode 0x0C = Equal Ordered (substring match)
    align 16
.hdr_scan:
    lea rax, [r13]
    sub rax, r11
    cmp rax, 16
    jl .hdr_scalar_tail

    pcmpistri xmm0, [r12 + r11], 0x0C
    jnc .hdr_no_match
    lea rax, [r11 + rcx]       ; rax = absolute candidate position

    push rax
    lea rdi, [r12 + rax]
    mov rsi, r14
    mov rcx, rbx
    repe cmpsb
    pop rax
    je .hdr_found

    lea r11, [rax + 1]
    jmp .hdr_scan

.hdr_no_match:
    add r11, 16
    jmp .hdr_scan

.hdr_scalar_tail:
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
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.hdr_found:
    add rax, rbx                ; value start = needle_start + needle_len
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.hdr_not_found:
    mov rax, -1
    SAFE_VZEROUPPER
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; ============================================================================
; ws_unmask4 — Multi-buffer parallel unmask (up to 4 frames)
;
; C: void ws_unmask4(uint8_t *data, const uint32_t *offsets,
;                    const uint32_t *lengths, const uint8_t *masks,
;                    uint32_t count);
;
; rdi=data  rsi=offsets  rdx=lengths  rcx=masks  r8d=count
;
; Processes up to 4 frames simultaneously using independent ZMM register
; sets. For frames <= 64 bytes (typical WebSocket control frames), each
; frame is a single opmask load + XOR + opmask store — 3 instructions
; with full ILP across all 4 frames.
;
; For frames > 64 bytes, processes 64-byte chunks from each active frame
; in an interleaved loop, then handles tails with opmask.
;
; Requires cpu_tier >= 3 (AVX-512 + BMI2). Caller must gate on this.
; ============================================================================
global ws_unmask4
ws_unmask4:
    test r8d, r8d
    jz .u4_ret_early

    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp

    ; Save base pointer and count
    mov rbp, rdi                ; rbp = data base pointer

    ; Load masks into ZMM0-ZMM3 (broadcast 4-byte mask to all lanes)
    vpbroadcastd zmm0, [rcx]
    cmp r8d, 1
    je .u4_load_done
    vpbroadcastd zmm1, [rcx + 4]
    cmp r8d, 2
    je .u4_load_done
    vpbroadcastd zmm2, [rcx + 8]
    cmp r8d, 3
    je .u4_load_done
    vpbroadcastd zmm3, [rcx + 12]

.u4_load_done:
    ; Load offsets into r9-r12 (as byte offsets from data base)
    mov r9d, [rsi]              ; offset0
    cmp r8d, 1
    je .u4_offsets_done
    mov r10d, [rsi + 4]         ; offset1
    cmp r8d, 2
    je .u4_offsets_done
    mov r11d, [rsi + 8]         ; offset2
    cmp r8d, 3
    je .u4_offsets_done
    mov r12d, [rsi + 12]        ; offset3

.u4_offsets_done:
    ; Load lengths into r13-rbx
    mov r13d, [rdx]             ; len0
    cmp r8d, 1
    je .u4_lens_done
    mov r14d, [rdx + 4]         ; len1
    cmp r8d, 2
    je .u4_lens_done
    mov r15d, [rdx + 8]         ; len2
    cmp r8d, 3
    je .u4_lens_done
    mov ebx, [rdx + 12]         ; len3

.u4_lens_done:
    ; ---- Interleaved 64-byte bulk loop ----
    ; Find the minimum length across active frames to determine how many
    ; full 64-byte iterations we can do for ALL frames simultaneously.
    ; This maximizes ILP by keeping all frames in lockstep.

    ; Compute min_len across active frames
    mov eax, r13d               ; min = len0
    cmp r8d, 1
    je .u4_min_done
    cmp r14d, eax
    cmovb eax, r14d
    cmp r8d, 2
    je .u4_min_done
    cmp r15d, eax
    cmovb eax, r15d
    cmp r8d, 3
    je .u4_min_done
    cmp ebx, eax
    cmovb eax, ebx

.u4_min_done:
    ; eax = min_len. Process full 64-byte chunks that ALL frames can do.
    mov ecx, eax
    shr ecx, 6                  ; ecx = number of full 64-byte iterations
    jz .u4_tails

    ; Dispatch based on count for the bulk loop
    cmp r8d, 4
    je .u4_bulk4
    cmp r8d, 3
    je .u4_bulk3
    cmp r8d, 2
    je .u4_bulk2
    ; count == 1: fall through to bulk1

    ; ---- Bulk loop: 1 frame ----
    align 32
.u4_bulk1:
    vpxord zmm4, zmm0, [rbp + r9]
    vmovdqu64 [rbp + r9], zmm4
    add r9, 64
    sub r13d, 64
    dec ecx
    jnz .u4_bulk1
    jmp .u4_tails

    ; ---- Bulk loop: 2 frames ----
    align 32
.u4_bulk2:
    vpxord zmm4, zmm0, [rbp + r9]
    vpxord zmm5, zmm1, [rbp + r10]
    vmovdqu64 [rbp + r9], zmm4
    vmovdqu64 [rbp + r10], zmm5
    add r9, 64
    add r10, 64
    sub r13d, 64
    sub r14d, 64
    dec ecx
    jnz .u4_bulk2
    jmp .u4_tails

    ; ---- Bulk loop: 3 frames ----
    align 32
.u4_bulk3:
    vpxord zmm4, zmm0, [rbp + r9]
    vpxord zmm5, zmm1, [rbp + r10]
    vpxord zmm6, zmm2, [rbp + r11]
    vmovdqu64 [rbp + r9], zmm4
    vmovdqu64 [rbp + r10], zmm5
    vmovdqu64 [rbp + r11], zmm6
    add r9, 64
    add r10, 64
    add r11, 64
    sub r13d, 64
    sub r14d, 64
    sub r15d, 64
    dec ecx
    jnz .u4_bulk3
    jmp .u4_tails

    ; ---- Bulk loop: 4 frames (maximum ILP) ----
    align 32
.u4_bulk4:
    vpxord zmm4, zmm0, [rbp + r9]
    vpxord zmm5, zmm1, [rbp + r10]
    vpxord zmm6, zmm2, [rbp + r11]
    vpxord zmm7, zmm3, [rbp + r12]
    vmovdqu64 [rbp + r9], zmm4
    vmovdqu64 [rbp + r10], zmm5
    vmovdqu64 [rbp + r11], zmm6
    vmovdqu64 [rbp + r12], zmm7
    add r9, 64
    add r10, 64
    add r11, 64
    add r12, 64
    sub r13d, 64
    sub r14d, 64
    sub r15d, 64
    sub ebx, 64
    dec ecx
    jnz .u4_bulk4

    ; ---- Per-frame tails: handle remaining bytes with opmask ----
.u4_tails:
    ; Frame 0 tail (always present since count >= 1)
    test r13d, r13d
    jz .u4_tail1

    ; Process remaining full 64-byte chunks for frame 0
    mov eax, r13d
    shr eax, 6
    jz .u4_tail0_final
.u4_tail0_64:
    vpxord zmm4, zmm0, [rbp + r9]
    vmovdqu64 [rbp + r9], zmm4
    add r9, 64
    sub r13d, 64
    dec eax
    jnz .u4_tail0_64
.u4_tail0_final:
    ; Opmask tail for frame 0
    mov rax, -1
    mov ecx, r13d
    bzhi rax, rax, rcx
    kmovq k1, rax
    vmovdqu8 zmm4{k1}{z}, [rbp + r9]
    vpxord zmm4, zmm4, zmm0
    vmovdqu8 [rbp + r9]{k1}, zmm4

.u4_tail1:
    cmp r8d, 2
    jb .u4_done
    test r14d, r14d
    jz .u4_tail2

    mov eax, r14d
    shr eax, 6
    jz .u4_tail1_final
.u4_tail1_64:
    vpxord zmm5, zmm1, [rbp + r10]
    vmovdqu64 [rbp + r10], zmm5
    add r10, 64
    sub r14d, 64
    dec eax
    jnz .u4_tail1_64
.u4_tail1_final:
    mov rax, -1
    mov ecx, r14d
    bzhi rax, rax, rcx
    kmovq k2, rax
    vmovdqu8 zmm5{k2}{z}, [rbp + r10]
    vpxord zmm5, zmm5, zmm1
    vmovdqu8 [rbp + r10]{k2}, zmm5

.u4_tail2:
    cmp r8d, 3
    jb .u4_done
    test r15d, r15d
    jz .u4_tail3

    mov eax, r15d
    shr eax, 6
    jz .u4_tail2_final
.u4_tail2_64:
    vpxord zmm6, zmm2, [rbp + r11]
    vmovdqu64 [rbp + r11], zmm6
    add r11, 64
    sub r15d, 64
    dec eax
    jnz .u4_tail2_64
.u4_tail2_final:
    mov rax, -1
    mov ecx, r15d
    bzhi rax, rax, rcx
    kmovq k3, rax
    vmovdqu8 zmm6{k3}{z}, [rbp + r11]
    vpxord zmm6, zmm6, zmm2
    vmovdqu8 [rbp + r11]{k3}, zmm6

.u4_tail3:
    cmp r8d, 4
    jb .u4_done
    test ebx, ebx
    jz .u4_done

    mov eax, ebx
    shr eax, 6
    jz .u4_tail3_final
.u4_tail3_64:
    vpxord zmm7, zmm3, [rbp + r12]
    vmovdqu64 [rbp + r12], zmm7
    add r12, 64
    sub ebx, 64
    dec eax
    jnz .u4_tail3_64
.u4_tail3_final:
    mov rax, -1
    mov ecx, ebx
    bzhi rax, rax, rcx
    kmovq k4, rax
    vmovdqu8 zmm7{k4}{z}, [rbp + r12]
    vpxord zmm7, zmm7, zmm3
    vmovdqu8 [rbp + r12]{k4}, zmm7

.u4_done:
    SAFE_VZEROUPPER
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
.u4_ret_early:
    ret


; ============================================================================
; ws_mask4 — Multi-buffer parallel mask (up to 4 frames, src != dst)
;
; C: void ws_mask4(const uint8_t *src, uint8_t *dst,
;                  const uint32_t *offsets, const uint32_t *lengths,
;                  const uint8_t *masks, uint32_t count);
;
; rdi=src  rsi=dst  rdx=offsets  rcx=lengths  r8=masks  r9d=count
;
; Same parallel approach as ws_unmask4 but reads from src, writes to dst.
; Requires cpu_tier >= 3 (AVX-512 + BMI2). Caller must gate on this.
; ============================================================================
global ws_mask4
ws_mask4:
    test r9d, r9d
    jz .m4_ret_early

    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp

    ; Save base pointers and count
    mov rbp, rdi                ; rbp = src base
    mov rdi, rsi                ; rdi = dst base (reuse rdi since src is in rbp)

    ; Load masks into ZMM0-ZMM3
    vpbroadcastd zmm0, [r8]
    cmp r9d, 1
    je .m4_load_done
    vpbroadcastd zmm1, [r8 + 4]
    cmp r9d, 2
    je .m4_load_done
    vpbroadcastd zmm2, [r8 + 8]
    cmp r9d, 3
    je .m4_load_done
    vpbroadcastd zmm3, [r8 + 12]

.m4_load_done:
    ; Load offsets (rdx = offsets pointer)
    mov r10d, [rdx]             ; offset0
    cmp r9d, 1
    je .m4_offsets_done
    mov r11d, [rdx + 4]         ; offset1
    cmp r9d, 2
    je .m4_offsets_done
    mov r12d, [rdx + 8]         ; offset2
    cmp r9d, 3
    je .m4_offsets_done
    mov r13d, [rdx + 12]        ; offset3

.m4_offsets_done:
    ; Load lengths (rcx = lengths pointer)
    mov r14d, [rcx]             ; len0
    cmp r9d, 1
    je .m4_lens_done
    mov r15d, [rcx + 4]         ; len1
    cmp r9d, 2
    je .m4_lens_done
    mov ebx, [rcx + 8]          ; len2
    cmp r9d, 3
    je .m4_lens_done
    mov esi, [rcx + 12]         ; len3 (rsi is free now; dst is in rdi)

.m4_lens_done:
    ; Save count in r8d (r8 was masks, now free since masks are in ZMMs)
    mov r8d, r9d

    ; Compute min_len across active frames
    mov eax, r14d               ; min = len0
    cmp r8d, 1
    je .m4_min_done
    cmp r15d, eax
    cmovb eax, r15d
    cmp r8d, 2
    je .m4_min_done
    cmp ebx, eax
    cmovb eax, ebx
    cmp r8d, 3
    je .m4_min_done
    cmp esi, eax
    cmovb eax, esi

.m4_min_done:
    mov ecx, eax
    shr ecx, 6                  ; ecx = full 64-byte iterations
    jz .m4_tails

    cmp r8d, 4
    je .m4_bulk4
    cmp r8d, 3
    je .m4_bulk3
    cmp r8d, 2
    je .m4_bulk2

    ; ---- Bulk loop: 1 frame (src != dst) ----
    align 32
.m4_bulk1:
    vpxord zmm4, zmm0, [rbp + r10]
    vmovdqu64 [rdi + r10], zmm4
    add r10, 64
    sub r14d, 64
    dec ecx
    jnz .m4_bulk1
    jmp .m4_tails

    ; ---- Bulk loop: 2 frames ----
    align 32
.m4_bulk2:
    vpxord zmm4, zmm0, [rbp + r10]
    vpxord zmm5, zmm1, [rbp + r11]
    vmovdqu64 [rdi + r10], zmm4
    vmovdqu64 [rdi + r11], zmm5
    add r10, 64
    add r11, 64
    sub r14d, 64
    sub r15d, 64
    dec ecx
    jnz .m4_bulk2
    jmp .m4_tails

    ; ---- Bulk loop: 3 frames ----
    align 32
.m4_bulk3:
    vpxord zmm4, zmm0, [rbp + r10]
    vpxord zmm5, zmm1, [rbp + r11]
    vpxord zmm6, zmm2, [rbp + r12]
    vmovdqu64 [rdi + r10], zmm4
    vmovdqu64 [rdi + r11], zmm5
    vmovdqu64 [rdi + r12], zmm6
    add r10, 64
    add r11, 64
    add r12, 64
    sub r14d, 64
    sub r15d, 64
    sub ebx, 64
    dec ecx
    jnz .m4_bulk3
    jmp .m4_tails

    ; ---- Bulk loop: 4 frames (maximum ILP) ----
    align 32
.m4_bulk4:
    vpxord zmm4, zmm0, [rbp + r10]
    vpxord zmm5, zmm1, [rbp + r11]
    vpxord zmm6, zmm2, [rbp + r12]
    vpxord zmm7, zmm3, [rbp + r13]
    vmovdqu64 [rdi + r10], zmm4
    vmovdqu64 [rdi + r11], zmm5
    vmovdqu64 [rdi + r12], zmm6
    vmovdqu64 [rdi + r13], zmm7
    add r10, 64
    add r11, 64
    add r12, 64
    add r13, 64
    sub r14d, 64
    sub r15d, 64
    sub ebx, 64
    sub esi, 64
    dec ecx
    jnz .m4_bulk4

    ; ---- Per-frame tails (src != dst) ----
.m4_tails:
    ; Frame 0 tail
    test r14d, r14d
    jz .m4_tail1

    mov eax, r14d
    shr eax, 6
    jz .m4_tail0_final
.m4_tail0_64:
    vpxord zmm4, zmm0, [rbp + r10]
    vmovdqu64 [rdi + r10], zmm4
    add r10, 64
    sub r14d, 64
    dec eax
    jnz .m4_tail0_64
.m4_tail0_final:
    mov rax, -1
    mov ecx, r14d
    bzhi rax, rax, rcx
    kmovq k1, rax
    vmovdqu8 zmm4{k1}{z}, [rbp + r10]
    vpxord zmm4, zmm4, zmm0
    vmovdqu8 [rdi + r10]{k1}, zmm4

.m4_tail1:
    cmp r8d, 2
    jb .m4_done
    test r15d, r15d
    jz .m4_tail2

    mov eax, r15d
    shr eax, 6
    jz .m4_tail1_final
.m4_tail1_64:
    vpxord zmm5, zmm1, [rbp + r11]
    vmovdqu64 [rdi + r11], zmm5
    add r11, 64
    sub r15d, 64
    dec eax
    jnz .m4_tail1_64
.m4_tail1_final:
    mov rax, -1
    mov ecx, r15d
    bzhi rax, rax, rcx
    kmovq k2, rax
    vmovdqu8 zmm5{k2}{z}, [rbp + r11]
    vpxord zmm5, zmm5, zmm1
    vmovdqu8 [rdi + r11]{k2}, zmm5

.m4_tail2:
    cmp r8d, 3
    jb .m4_done
    test ebx, ebx
    jz .m4_tail3

    mov eax, ebx
    shr eax, 6
    jz .m4_tail2_final
.m4_tail2_64:
    vpxord zmm6, zmm2, [rbp + r12]
    vmovdqu64 [rdi + r12], zmm6
    add r12, 64
    sub ebx, 64
    dec eax
    jnz .m4_tail2_64
.m4_tail2_final:
    mov rax, -1
    mov ecx, ebx
    bzhi rax, rax, rcx
    kmovq k3, rax
    vmovdqu8 zmm6{k3}{z}, [rbp + r12]
    vpxord zmm6, zmm6, zmm2
    vmovdqu8 [rdi + r12]{k3}, zmm6

.m4_tail3:
    cmp r8d, 4
    jb .m4_done
    test esi, esi
    jz .m4_done

    mov eax, esi
    shr eax, 6
    jz .m4_tail3_final
.m4_tail3_64:
    vpxord zmm7, zmm3, [rbp + r13]
    vmovdqu64 [rdi + r13], zmm7
    add r13, 64
    sub esi, 64
    dec eax
    jnz .m4_tail3_64
.m4_tail3_final:
    mov rax, -1
    mov ecx, esi
    bzhi rax, rax, rcx
    kmovq k4, rax
    vmovdqu8 zmm7{k4}{z}, [rbp + r13]
    vpxord zmm7, zmm7, zmm3
    vmovdqu8 [rdi + r13]{k4}, zmm7

.m4_done:
    SAFE_VZEROUPPER
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
.m4_ret_early:
    ret


; ============================================================================
; ws_mask_gfni — GFNI experiment: benchmark comparison for WebSocket masking
;
; Identical signature to ws_mask:
;   rdi=src  rsi=mask_ptr  rdx=output  rcx=offset  r8=length
;
; GFNI EVALUATION — WHY GF2P8AFFINEQB CANNOT REPLACE VPXORD HERE
; ---------------------------------------------------------------
; GF2P8AFFINEQB dst, src1, src2, imm8 computes per byte:
;   dst[i] = GF2_matrix_multiply(src2_qword[i/8], src1[i]) XOR imm8
;
; To use it as XOR with mask byte m: set src2 = identity matrix
; (0x0102040810204080 per qword), then output = data XOR imm8.
; But imm8 is a single compile-time byte, while the WebSocket mask
; is a 4-byte repeating pattern [m0, m1, m2, m3]. This means:
;
;   Option A: 4 separate GF2P8AFFINEQB instructions per chunk, each
;             with a different imm8, plus blend/merge to combine.
;             Cost: 4 instructions + blending vs. 1 VPXORD.
;
;   Option B: Encode the mask into the matrix instead of imm8.
;             But the matrix is per-qword (8 bytes), and we need
;             per-byte XOR values — the matrix multiply can only
;             produce A*d, not d XOR m for varying m per byte.
;
;   Option C: Use GF2P8AFFINEQB as identity (no-op), then VPXORD.
;             Strictly worse: adds 3-cycle latency instruction.
;
; On Zen 4 specifically:
;   VPXORD:          ports 0/1/2/3, 1-cycle latency, 4/cycle throughput
;   GF2P8AFFINEQB:   ports 0/1,     3-cycle latency, 2/cycle throughput
;
; Conclusion: VPXORD is optimal for multi-byte XOR patterns.
; This function is a direct copy of the AVX-512 cached mask path
; to serve as a controlled benchmark baseline proving the finding.
;
; Gate: cpu_tier >= 3 (AVX-512) AND cpu_features bit 0 (GFNI)
; ============================================================================
global ws_mask_gfni
ws_mask_gfni:
    ; Require AVX-512 + GFNI; fall through to ws_mask if not available
    cmp dword [cpu_tier], 3
    jne ws_mask                     ; no AVX-512 → delegate to ws_mask
    test dword [cpu_features], 1    ; bit 0 = GFNI
    jz ws_mask                      ; no GFNI → delegate to ws_mask

    add rdx, rcx                    ; rdx = dest + offset
    mov rcx, r8                     ; rcx = length
    test rcx, rcx
    jz .gf_ret

    mov r8d, [rsi]                  ; 4-byte mask

    ; Small payloads: reuse GPR fast path from ws_mask
    cmp rcx, 128
    jb .gf_gpr_small

    ; ==================== AVX-512 MASK (GFNI baseline experiment) ====================
    vpbroadcastd zmm0, r8d

    ; Align destination (rdx) to 64-byte boundary using opmask partial store
    mov rax, rdx
    neg rax
    and rax, 63                     ; bytes to next 64-byte boundary
    jz .gf_512_aligned
    cmp rax, rcx                    ; preamble larger than total payload?
    jae .gf_512_tail                ; → skip alignment, do unaligned tail

    mov r9, -1
    bzhi r9, r9, rax
    kmovq k1, r9

    vmovdqu8 zmm1{k1}{z}, [rdi]
    vpxord zmm1, zmm1, zmm0
    vmovdqu8 [rdx]{k1}, zmm1

    add rdi, rax
    add rdx, rax
    sub rcx, rax

    ; Re-sync mask vector if advance was not a multiple of 4
    test al, 3
    jz .gf_512_aligned
    mov r9, rcx                     ; save length (need cl for ror)
    mov ecx, eax
    and ecx, 3
    shl ecx, 3                      ; rotation amount in bits
    ror r8d, cl
    mov rcx, r9
    vpbroadcastd zmm0, r8d

.gf_512_aligned:
    ; 8x unrolled: 512 bytes/iter (rdx now 64-byte aligned)
    mov rax, rcx
    shr rax, 9
    jz .gf_512_tail

    align 32
.gf_512_loop:
    prefetcht0 [rdi + 2048]
    vpxord zmm1, zmm0, [rdi]
    vpxord zmm2, zmm0, [rdi + 64]
    vpxord zmm3, zmm0, [rdi + 128]
    vpxord zmm4, zmm0, [rdi + 192]
    vpxord zmm5, zmm0, [rdi + 256]
    vpxord zmm6, zmm0, [rdi + 320]
    vpxord zmm7, zmm0, [rdi + 384]
    vpxord zmm8, zmm0, [rdi + 448]
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
    jnz .gf_512_loop

    and rcx, 511

.gf_512_tail:
    ; Handle remaining 0-511 bytes — full 64-byte chunks, then opmask tail
    test rcx, rcx
    jz .gf_512_done

    mov rax, rcx
    shr rax, 6                      ; full 64-byte chunks (0-7)
    jz .gf_512_final

.gf_512_full64:
    vpxord zmm1, zmm0, [rdi]
    vmovdqu64 [rdx], zmm1
    add rdi, 64
    add rdx, 64
    sub rcx, 64
    dec rax
    jnz .gf_512_full64

    ; ---- OPMASK TAIL: process exactly rcx remaining bytes (0-63) ----
.gf_512_final:
    mov rax, -1
    bzhi rax, rax, rcx
    kmovq k1, rax

    vmovdqu8 zmm1{k1}{z}, [rdi]
    vpxord zmm1, zmm1, zmm0
    vmovdqu8 [rdx]{k1}, zmm1

.gf_512_done:
    SAFE_VZEROUPPER
    ret

    ; Small payload (<128 bytes) — reuse GPR path logic
    ; RORX is safe here: ws_mask_gfni gates on AVX-512 + GFNI, so BMI2 is guaranteed.
.gf_gpr_small:
    rorx r9, r8, 32                ; r9 = r8d rotated to upper 32 bits
    or   r9, r8                     ; r9 = 8-byte mask (r8d duplicated)

    mov rax, rcx
    shr rax, 5                      ; 32-byte chunks
    jz .gf_gpr8_rem

    align 16
.gf_gpr32:
    mov r10, [rdi]
    mov r11, [rdi + 8]
    xor r10, r9
    xor r11, r9
    mov [rdx], r10
    mov [rdx + 8], r11
    mov r10, [rdi + 16]
    mov r11, [rdi + 24]
    xor r10, r9
    xor r11, r9
    mov [rdx + 16], r10
    mov [rdx + 24], r11
    add rdi, 32
    add rdx, 32
    dec rax
    jnz .gf_gpr32

    and rcx, 31

.gf_gpr8_rem:
    mov rax, rcx
    shr rax, 3
    jz .gf_scalar

.gf_gpr8:
    mov r10, [rdi]
    xor r10, r9
    mov [rdx], r10
    add rdi, 8
    add rdx, 8
    dec rax
    jnz .gf_gpr8

    and rcx, 7
    jz .gf_ret

.gf_scalar:
    mov rax, rcx
    shr rax, 2
    jz .gf_bytes
.gf_dword:
    mov r9d, [rdi]
    xor r9d, r8d
    mov [rdx], r9d
    add rdi, 4
    add rdx, 4
    dec rax
    jnz .gf_dword
    and rcx, 3
    jz .gf_ret
.gf_bytes:
    test rcx, rcx
    jz .gf_ret
    mov al, [rdi]
    xor al, r8b
    mov [rdx], al
    dec rcx
    jz .gf_ret
    ror r8d, 8
    mov al, [rdi + 1]
    xor al, r8b
    mov [rdx + 1], al
    dec rcx
    jz .gf_ret
    ror r8d, 8
    mov al, [rdi + 2]
    xor al, r8b
    mov [rdx + 2], al
.gf_ret:
    ret


; Non-executable stack
section .note.GNU-stack noalloc noexec nowrite progbits
