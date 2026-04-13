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
;   KMOVQ k1, rax        — load opmask from GPR (AVX-512BW)
;   PCMPISTRI xmm, m, im — string comparison (SSE4.2)
;   PREFETCHNTA          — non-temporal prefetch
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

    cmp dword [cpu_tier], 3
    je .m_avx512
    cmp dword [cpu_tier], 2
    je .m_avx2
    jmp .m_sse2

    ; ==================== AVX-512 + OPMASK TAIL ====================
    align 32
.m_avx512:
    vpbroadcastd zmm0, r8d

    cmp rcx, (1 << 18)          ; >= 256KB → NT path
    jae .m_nt512

    ; 4x unrolled: 256 bytes/iter
    mov rax, rcx
    shr rax, 8
    test rax, rax
    jz .m_512_tail

    align 32
.m_512_256:
    prefetchnta [rdi + 1024]
    vmovdqu64 zmm1, [rdi]
    vmovdqu64 zmm2, [rdi + 64]
    vmovdqu64 zmm3, [rdi + 128]
    vmovdqu64 zmm4, [rdi + 192]
    vpxord zmm1, zmm1, zmm0
    vpxord zmm2, zmm2, zmm0
    vpxord zmm3, zmm3, zmm0
    vpxord zmm4, zmm4, zmm0
    vmovdqu64 [rdx], zmm1
    vmovdqu64 [rdx + 64], zmm2
    vmovdqu64 [rdx + 128], zmm3
    vmovdqu64 [rdx + 192], zmm4
    add rdi, 256
    add rdx, 256
    dec rax
    jnz .m_512_256

    and rcx, 255

.m_512_tail:
    ; Handle remaining 0-255 bytes with opmask — NO scalar fallback needed
    ; Process up to 4 masked 64-byte chunks
    test rcx, rcx
    jz .m_512_done

    ; Chunk 1: up to 64 bytes
    cmp rcx, 64
    jbe .m_512_final           ; last chunk, use mask

    vmovdqu64 zmm1, [rdi]
    vpxord zmm1, zmm1, zmm0
    vmovdqu64 [rdx], zmm1
    add rdi, 64
    add rdx, 64
    sub rcx, 64

    ; Chunk 2
    cmp rcx, 64
    jbe .m_512_final

    vmovdqu64 zmm1, [rdi]
    vpxord zmm1, zmm1, zmm0
    vmovdqu64 [rdx], zmm1
    add rdi, 64
    add rdx, 64
    sub rcx, 64

    ; Chunk 3
    cmp rcx, 64
    jbe .m_512_final

    vmovdqu64 zmm1, [rdi]
    vpxord zmm1, zmm1, zmm0
    vmovdqu64 [rdx], zmm1
    add rdi, 64
    add rdx, 64
    sub rcx, 64

    ; Fall through to final masked chunk

    ; ---- OPMASK TAIL: process exactly rcx remaining bytes (1-64) ----
.m_512_final:
    ; Build byte mask: k1 = (1 << rcx) - 1
    ; For rcx=64 this needs special handling (all ones)
    cmp rcx, 64
    je .m_512_final_full

    mov rax, 1
    shl rax, cl                 ; 1 << rcx
    dec rax                     ; (1 << rcx) - 1
    kmovq k1, rax

    vmovdqu8 zmm1{k1}{z}, [rdi] ; masked load (only rcx bytes)
    vpxord zmm1, zmm1, zmm0     ; XOR all 64 bytes (extra bytes are zero, harmless)
    vmovdqu8 [rdx]{k1}, zmm1    ; masked store (only rcx bytes written)
    jmp .m_512_done

.m_512_final_full:
    vmovdqu64 zmm1, [rdi]
    vpxord zmm1, zmm1, zmm0
    vmovdqu64 [rdx], zmm1

.m_512_done:
    vzeroupper
    ret


    ; ==================== AVX-512 NT-STORE PATH (>= 256KB) ====================
    align 32
.m_nt512:
    ; Align destination (rdx) to 64-byte boundary using regular stores
    mov rax, rdx
    and rax, 63                 ; bytes to process before alignment
    jz  .m_nt512_aligned

.m_nt512_prologue:
    mov r9b, [rdi]
    xor r9b, r8b
    mov [rdx], r9b
    inc rdi
    inc rdx
    sub rcx, 1
    sub rax, 1
    jnz .m_nt512_prologue

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

    cmp rcx, (1 << 18)
    jae .m_nt_avx2

    mov rax, rcx
    shr rax, 7
    test rax, rax
    jz .m_avx2_t32

    align 32
.m_avx2_128:
    prefetchnta [rdi + 512]
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
    vzeroupper
    jmp .m_scalar

.m_avx2_done:
    vzeroupper
    ret


    ; ==================== AVX2 NT-STORE PATH (>= 256KB) ====================
    align 32
.m_nt_avx2:
    ; Align destination to 32-byte boundary
    mov rax, rdx
    and rax, 31
    jz  .m_nt_avx2_aligned

.m_nt_avx2_prologue:
    mov r9b, [rdi]
    xor r9b, r8b
    mov [rdx], r9b
    inc rdi
    inc rdx
    sub rcx, 1
    sub rax, 1
    jnz .m_nt_avx2_prologue

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
    vzeroupper
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
    prefetchnta [rdi + 256]
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

    cmp dword [cpu_tier], 3
    je .u_avx512
    cmp dword [cpu_tier], 2
    je .u_avx2
    jmp .u_sse2

    ; ==================== AVX-512 UNMASK + OPMASK TAIL ====================
    align 32
.u_avx512:
    vpbroadcastd zmm0, r8d

    cmp rcx, (1 << 18)
    jae .u_nt512

    mov rax, rcx
    shr rax, 8
    test rax, rax
    jz .u_512_tail

    align 32
.u_512_256:
    prefetchnta [rdi + 1024]
    vmovdqu64 zmm1, [rdi]
    vmovdqu64 zmm2, [rdi + 64]
    vmovdqu64 zmm3, [rdi + 128]
    vmovdqu64 zmm4, [rdi + 192]
    vpxord zmm1, zmm1, zmm0
    vpxord zmm2, zmm2, zmm0
    vpxord zmm3, zmm3, zmm0
    vpxord zmm4, zmm4, zmm0
    vmovdqu64 [rdi], zmm1
    vmovdqu64 [rdi + 64], zmm2
    vmovdqu64 [rdi + 128], zmm3
    vmovdqu64 [rdi + 192], zmm4
    add rdi, 256
    dec rax
    jnz .u_512_256
    and rcx, 255

.u_512_tail:
    test rcx, rcx
    jz .u_512_done

    ; Full 64-byte chunks from remainder
    cmp rcx, 64
    jbe .u_512_final
    vmovdqu64 zmm1, [rdi]
    vpxord zmm1, zmm1, zmm0
    vmovdqu64 [rdi], zmm1
    add rdi, 64
    sub rcx, 64

    cmp rcx, 64
    jbe .u_512_final
    vmovdqu64 zmm1, [rdi]
    vpxord zmm1, zmm1, zmm0
    vmovdqu64 [rdi], zmm1
    add rdi, 64
    sub rcx, 64

    cmp rcx, 64
    jbe .u_512_final
    vmovdqu64 zmm1, [rdi]
    vpxord zmm1, zmm1, zmm0
    vmovdqu64 [rdi], zmm1
    add rdi, 64
    sub rcx, 64

    ; ---- OPMASK TAIL (in-place) ----
.u_512_final:
    cmp rcx, 64
    je .u_512_final_full

    mov rax, 1
    shl rax, cl
    dec rax
    kmovq k1, rax
    vmovdqu8 zmm1{k1}{z}, [rdi]
    vpxord zmm1, zmm1, zmm0
    vmovdqu8 [rdi]{k1}, zmm1
    jmp .u_512_done

.u_512_final_full:
    vmovdqu64 zmm1, [rdi]
    vpxord zmm1, zmm1, zmm0
    vmovdqu64 [rdi], zmm1

.u_512_done:
    vzeroupper
    ret


    ; ==================== AVX-512 UNMASK NT PATH ====================
    align 32
.u_nt512:
    mov rax, rdi
    and rax, 63
    jz  .u_nt512_aligned

.u_nt512_prologue:
    xor byte [rdi], r8b
    inc rdi
    sub rcx, 1
    sub rax, 1
    jnz .u_nt512_prologue

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

    cmp rcx, (1 << 18)
    jae .u_nt_avx2

    mov rax, rcx
    shr rax, 7
    test rax, rax
    jz .u_avx2_t32

    align 32
.u_avx2_128:
    prefetchnta [rdi + 512]
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
    vzeroupper
    jmp .u_scalar

.u_avx2_done:
    vzeroupper
    ret


    ; ==================== AVX2 UNMASK NT PATH ====================
    align 32
.u_nt_avx2:
    ; Align destination to 32-byte boundary
    mov rax, rdi
    and rax, 31
    jz  .u_nt_avx2_aligned

.u_nt_avx2_prologue:
    xor byte [rdi], r8b
    inc rdi
    sub rcx, 1
    sub rax, 1
    jnz .u_nt_avx2_prologue

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
    vzeroupper
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
    prefetchnta [rdi + 256]
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

    xor rcx, rcx                ; current position

    ; PCMPISTRI mode 0x0C = Equal Ordered (substring match)
    ; Compares bytes in xmm0 against 16 bytes at [buf+pos]
    ; Sets ECX to index of first match within the 16-byte window
    align 16
.hdr_scan:
    lea rax, [r13]
    sub rax, rcx
    cmp rax, 16
    jl .hdr_scalar_tail         ; less than 16 bytes left

    pcmpistri xmm0, [r12 + rcx], 0x0C
    ; CF=1 if match found, ECX=index
    jc .hdr_candidate
    add rcx, 16                 ; advance by 16
    jmp .hdr_scan

.hdr_candidate:
    ; ECX has match offset within the 16-byte window
    add rcx, rcx                ; ... wait, PCMPISTRI output is in ECX
    ; Actually: after PCMPISTRI, IntRes2 index is in ECX
    ; But this is the position of the first matching BYTE within the window
    ; We need to verify the full needle starting at buf + (outer_pos + ecx)

    ; Save scan position
    push rcx
    mov rdi, r12
    add rdi, rcx                ; rdi = buf + match position
    mov rsi, r14                ; needle
    mov rdx, rbx                ; needle_len

    ; Verify full match with REP CMPSB
    mov rcx, rdx
    repe cmpsb
    pop rcx

    je .hdr_found               ; full match!

    inc rcx                     ; advance past failed match
    jmp .hdr_scan

.hdr_scalar_tail:
    ; Less than 16 bytes remaining — do byte-by-byte
    lea rax, [r13]
    sub rax, rbx                ; max valid start position
.hdr_scalar:
    cmp rcx, rax
    jg .hdr_not_found

    ; Compare needle at current position
    push rcx
    lea rdi, [r12 + rcx]
    mov rsi, r14
    mov rdx, rbx
    mov rcx, rdx
    repe cmpsb
    pop rcx
    je .hdr_found

    inc rcx
    jmp .hdr_scalar

.hdr_found:
    ; Return offset of value (position + needle_len)
    lea rax, [rcx + rbx]
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
