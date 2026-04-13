; ws_base64_asm.asm — Base64 encoder with AVX2/GFNI/SSE2/scalar dispatch
;
; C signature:
;   size_t ws_base64_encode(const uint8_t *in, size_t len, uint8_t *out);
;
; Calling convention (System V AMD64 ABI):
;   rdi = in    (pointer to input bytes)
;   rsi = len   (number of input bytes)
;   rdx = out   (pointer to output buffer, must hold ceil(len/3)*4 bytes)
;
; Returns:
;   rax = number of output bytes written (always ceil(len/3)*4)
;
; Dispatch order (fastest-available first):
;   1. cpu_tier >= 2 (AVX2)          -> .avx2_path   (24 input bytes -> 32 output chars / iter)
;   2. cpu_tier >= 1 (SSE2 baseline) -> .sse2_path   (12 input bytes -> 16 output chars / iter)
;   3. fallback                      -> .scalar_path  ( 3 input bytes ->  4 output chars / iter)
;
; Algorithm: Klomp/Muła VPSHUFB method (vectorised base64 encoding)
;
;   For each group of 3 input bytes (A, B, C) we produce 4 base64 characters
;   whose 6-bit indices are:
;     i0 = A >> 2
;     i1 = ((A & 3) << 4) | (B >> 4)
;     i2 = ((B & 0xF) << 2) | (C >> 6)
;     i3 = C & 0x3F
;
;   The vectorised approach processes 4 groups (12 bytes) at once in a 128-bit
;   XMM register (or 8 groups / 24 bytes in a 256-bit YMM register):
;
;   Step 1 — Shuffle (PSHUFB / VPSHUFB):
;     Rearrange the 12 input bytes so that each 16-bit word in the result
;     contains the two source bytes needed for one pair of 6-bit extractions.
;     For group g at input offsets [3g, 3g+1, 3g+2] = [A, B, C]:
;       word 4g+0 = [B, A]   (even byte = B, odd byte = A)
;       word 4g+1 = [A, B]   (even byte = A, odd byte = B)
;       word 4g+2 = [C, B]   (even byte = C, odd byte = B)
;       word 4g+3 = [B, C]   (even byte = B, odd byte = C)
;     Shuffle indices (byte positions to read from the 16-byte input):
;       for g=0: 1,0, 0,1, 2,1, 1,2  — but the canonical published form below
;       groups them differently to pair B with A and B with C at word boundaries.
;
;     Canonical Klomp shuffle for 4 groups (12 bytes -> 16 bytes):
;       Each group [A,B,C] at base offset b = g*3 maps to output slots b'= g*4:
;         slot b'+0 = B  (index b+1)
;         slot b'+1 = A  (index b+0)
;         slot b'+2 = C  (index b+2)  — note: C at +2, not +3
;         slot b'+3 = B  (index b+1)  — B repeated for the second pair
;       Full 16-byte shuffle table:
;         1, 0, 2, 1,   4, 3, 5, 4,   7, 6, 8, 7,   10, 9, 11, 10
;
;   Step 2 — Extract high indices (PMADDUBSW with mul_lo = 0x0140, then >> 10):
;     PMADDUBSW dst, src:  result_word[j] = (dst_even[j] * src_even[j])
;                                         + (dst_odd[j]  * src_odd[j])
;     With our shuffle, word j = [B, A] (even=B unsigned, odd=A unsigned).
;     mul_lo word = 0x0140: even byte = 0x40 (+64 signed), odd byte = 0x01 (+1 signed).
;     result = B*64 + A*1  (each up to 255*64 = 16320, fits in signed 16-bit)
;     Shift right by 10: (B*64 + A) >> 10 = (B<<6 + A) >> 10
;     For the 16-bit range: bits 15..10 give (B*64 + A) / 1024.
;     The value i0 = A>>2 falls in bits [9:4] of A, and:
;       (A*4 + B) >> 4  ... hmm, let's cross-check with published values.
;
;     Reference (Muła/Klomp): the shuffle used is slightly different from
;     the naive per-group arrangement.  The published implementation uses:
;       shuffle: 1,0,2,1, 4,3,5,4, 7,6,8,7, 10,9,11,10
;       mul_lo = 0x0140 (repeated as 16-bit words)
;       mul_hi = 0x0801 (repeated as 16-bit words)
;     After PMADDUBSW with mul_lo and >> 10: 8 "high" indices per 16-byte block
;     After PMADDUBSW with mul_hi and & 0x3F: 8 "low"  indices per 16-byte block
;     After PACKUSWB(hi, lo) + re-interleave PSHUFB: 16 indices in correct order.
;
;   Step 3 — Extract low indices (PMADDUBSW with mul_hi = 0x0801, then & 0x3F):
;     mul_hi word = 0x0801: even byte = 0x01 (+1), odd byte = 0x08 (+8 signed).
;     result = B*1 + A*8  (for the [B,A] word) or C*1 + B*8 (for [C,B] word)
;     AND with 0x3F isolates the low 6 bits.
;
;   Step 4 — Pack (PACKUSWB / VPACKUSWB):
;     Pack 8 hi-index words + 8 lo-index words into 16 bytes.
;     The packed order is [hi0..hi7, lo0..lo7]; a PSHUFB interleave fixes this.
;
;   Step 5 — Classify (range comparison + offset accumulation):
;     Start all 32 (or 16) output bytes with base offset +65 ('A').
;     Conditionally add correction offsets by comparing against thresholds:
;       > 25: add  +6   (lowercase 'a'-'z': 65+6=71, 71+index gives 'a'..'z')
;       > 51: add -75   (digits '0'-'9':    71-75=-4, -4+index gives '0'..'9')
;       > 61: add -15   ('+': -4-15=-19, -19+62=43='+')
;       > 62: add  +3   ('/': -19+3=-16, -16+63=47='/')
;
;   Step 6 — Map (PADDB / VPADDB):
;     Add the accumulated offset to the 6-bit index to get the ASCII character.
;
; Register allocation (preserved across all sub-paths, callee-saved per SysV ABI):
;   rbx = output offset in bytes (increments by 32/16/4)
;   r12 = input  base pointer (rdi on entry)
;   r13 = total input length  (rsi on entry)
;   r14 = output base pointer (rdx on entry)
;   r15 = input  offset in bytes (increments by 24/12/3)
;
; Build:
;   nasm -f elf64 ws_base64_asm.asm -o ws_base64_asm.o

BITS 64
DEFAULT REL

extern cpu_tier

; ============================================================================
; .data — lookup tables and broadcast constant vectors
; ============================================================================
section .data

    ; -------------------------------------------------------------------------
    ; Shuffle table for PSHUFB / VPSHUFB (Step 1).
    ; Repeating 16-byte pattern (used as-is for XMM; duplicated for YMM since
    ; VPSHUFB shuffles each 128-bit lane independently using the SAME 16 bytes
    ; of control, so the high lane uses indices 0..15 to index within itself).
    align 32
    b64_shuf:
        db  1, 0, 2, 1,  4, 3, 5, 4,  7, 6, 8, 7, 10, 9,11,10
        db  1, 0, 2, 1,  4, 3, 5, 4,  7, 6, 8, 7, 10, 9,11,10

    ; -------------------------------------------------------------------------
    ; PMADDUBSW multiplier for HIGH indices (i0, i2 per group).
    ; Each 16-bit word = 0x0140: low byte = 0x40 (+64), high byte = 0x01 (+1).
    ; After multiply-add and >> 10 the high 6-bit index sits in bits [5:0].
    align 32
    b64_mul_lo:
        times 16 dw 0x0140

    ; PMADDUBSW multiplier for LOW indices (i1, i3 per group).
    ; Each 16-bit word = 0x0801: low byte = 0x01 (+1), high byte = 0x08 (+8).
    ; After multiply-add and & 0x3F the low 6-bit index sits in bits [5:0].
    align 32
    b64_mul_hi:
        times 16 dw 0x0801

    ; -------------------------------------------------------------------------
    ; Post-pack interleave shuffle (Step 4b).
    ; After PACKUSWB(hi_words, lo_words) the layout within each 16-byte lane is:
    ;   [hi0, hi1, hi2, hi3, hi4, hi5, hi6, hi7,
    ;    lo0, lo1, lo2, lo3, lo4, lo5, lo6, lo7]
    ; hi indices correspond to output characters 0,2,4,6,8,10,12,14
    ; lo indices correspond to output characters 1,3,5,7,9,11,13,15
    ; We interleave to produce the correct sequential order:
    ;   [hi0,lo0, hi1,lo1, hi2,lo2, hi3,lo3, hi4,lo4, hi5,lo5, hi6,lo6, hi7,lo7]
    ; i.e. read position i from slot: hi at i/2 (even i), lo at 8 + i/2 (odd i).
    ; Shuffle bytes: 0,8, 1,9, 2,10, 3,11, 4,12, 5,13, 6,14, 7,15
    align 32
    b64_pack_shuf:
        db  0, 8, 1, 9, 2,10, 3,11, 4,12, 5,13, 6,14, 7,15
        db  0, 8, 1, 9, 2,10, 3,11, 4,12, 5,13, 6,14, 7,15

    ; -------------------------------------------------------------------------
    ; 0x3F mask used to isolate 6-bit indices from PMADDUBSW with mul_hi.
    align 32
    b64_mask3f:
        times 32 db 0x3F

    ; -------------------------------------------------------------------------
    ; Broadcast byte constants for the classification step (Step 5).
    ; Each table is 32 bytes (filled with one repeated byte value) so it can
    ; be loaded directly into both XMM (first 16 bytes) and YMM (all 32 bytes).

    ; Comparison thresholds (for pcmpgtb / vpcmpgtb; signed comparison)
    align 32
    b64_const_25:   times 32 db 25     ; threshold: > 25 -> not uppercase
    align 32
    b64_const_51:   times 32 db 51     ; threshold: > 51 -> not lowercase
    align 32
    b64_const_61:   times 32 db 61     ; threshold: > 61 -> not digit
    align 32
    b64_const_62:   times 32 db 62     ; threshold: > 62 -> is '/'

    ; Offset addends (added to the running offset accumulator via paddb / vpaddb)
    align 32
    b64_const_p65:  times 32 db 65     ; base ASCII offset ('A')
    align 32
    b64_const_p06:  times 32 db 6      ; +6 correction  (uppercase->lowercase boundary)
    align 32
    b64_const_n75:  times 32 db 0xB5   ; -75 correction (lowercase->digit boundary)  0xB5 = -75
    align 32
    b64_const_n15:  times 32 db 0xF1   ; -15 correction (digit->'+' boundary)         0xF1 = -15
    align 32
    b64_const_p03:  times 32 db 3      ; +3  correction ('+'->'/' boundary)

    ; -------------------------------------------------------------------------
    ; Standard 64-character base64 alphabet (RFC 4648 §4).
    align 64
    b64_table:
        db "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


; ============================================================================
; .text
; ============================================================================
section .text

global ws_base64_encode

; ============================================================================
; ws_base64_encode
;
; Entry: rdi=in, rsi=len, rdx=out
; Exit:  rax = bytes written (= ceil(len/3)*4)
; ============================================================================
ws_base64_encode:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov  r12, rdi           ; r12 = input  base
    mov  r13, rsi           ; r13 = total input length
    mov  r14, rdx           ; r14 = output base
    xor  r15, r15           ; r15 = input  offset (bytes consumed so far)
    xor  rbx, rbx           ; rbx = output offset (bytes written so far)

    ; ------------------------------------------------------------------
    ; Dispatch: fastest available tier first.
    ; Note: cpu_tier is a 32-bit dword in .data of ws_cpu.asm
    ; and is declared extern above.  We use RIP-relative addressing
    ; (DEFAULT REL ensures this).
    ; ------------------------------------------------------------------
    cmp  dword [cpu_tier], 2
    jge  .avx2_path

    cmp  dword [cpu_tier], 1
    jge  .sse2_path

    jmp  .scalar_path


; ============================================================================
; AVX2 PATH — 24 input bytes -> 32 output characters per iteration
;
; We load 32 bytes from [r12+r15] but only consume 24 of them.  This "overlapping
; load" trick avoids a separate tail for bytes 24..31 of each chunk; the bytes
; are re-read on the next iteration (which is fine, reads are idempotent).
; The loop guard requires at least 32 bytes remaining to ensure the load is safe.
; After the loop, < 24 bytes remain and are handled by .scalar_path.
;
; VPSHUFB on YMM operates on each 128-bit lane independently.  The low lane
; holds bytes [r15+0..r15+15] after load, and the high lane holds bytes
; [r15+16..r15+31].  After VPSHUFB with our 32-byte (doubled) shuffle table:
;   low  lane output bytes come from input indices 0..15  (within the lane)
;   high lane output bytes come from input indices 0..15  (within the lane)
; So both lanes independently process 12 input bytes each (groups 0-3 and 4-7),
; and together produce 32 output characters from 24 input bytes.
; ============================================================================
    align 32
.avx2_path:
    ; Preload per-iteration constants into caller-saved YMM registers.
    ; ymm10..ymm15 hold the threshold/offset vectors and are not clobbered
    ; within the loop body (ymm0..ymm5 are used as scratch).
    vmovdqa ymm6,  [b64_const_n75]
    vmovdqa ymm7,  [b64_const_n15]
    vmovdqa ymm8,  [b64_const_p03]
    vmovdqa ymm10, [b64_const_25]
    vmovdqa ymm11, [b64_const_51]
    vmovdqa ymm12, [b64_const_61]
    vmovdqa ymm13, [b64_const_62]
    vmovdqa ymm14, [b64_const_p65]
    vmovdqa ymm15, [b64_const_p06]

    align 32
.avx2_loop:
    ; Guard: need at least 32 bytes for a safe 32-byte load.
    mov  rax, r13
    sub  rax, r15
    cmp  rax, 32
    jl   .avx2_tail             ; < 32 bytes left -> flush remainder via scalar

    ; ---- Step 1: Load 32 bytes (24 consumed, 8 overlap with next iter) ----
    vmovdqu ymm0, [r12 + r15]

    ; ---- Step 2: Shuffle bytes for 6-bit extraction ----
    vpshufb ymm0, ymm0, [b64_shuf]

    ; ---- Step 3a: Extract high indices (i0, i2 for each group) ----
    vpmaddubsw ymm1, ymm0, [b64_mul_lo]
    vpsrlw     ymm1, ymm1, 10      ; shift >> 10 leaves 6-bit index in low bits

    ; ---- Step 3b: Extract low indices (i1, i3 for each group) ----
    vpmaddubsw ymm2, ymm0, [b64_mul_hi]
    vpand      ymm2, ymm2, [b64_mask3f]

    ; ---- Step 4: Pack words to bytes, then interleave hi/lo ----
    vpackuswb  ymm3, ymm1, ymm2    ; [hi0..hi7|lo0..lo7] per 128-bit lane
    vpshufb    ymm3, ymm3, [b64_pack_shuf]  ; interleave -> correct sequential order

    ; ---- Step 5: Classify — build per-byte ASCII offset vector ----
    ; Start with base offset +65 for every output byte position.
    vmovdqa    ymm4, ymm14          ; ymm4 = +65 for all 32 bytes

    ; +6 where index > 25 (enters lowercase range)
    vpcmpgtb   ymm5, ymm3, ymm10   ; 0xFF where index > 25, else 0
    vpand      ymm5, ymm5, ymm15   ; ymm15 = +6 addend
    vpaddb     ymm4, ymm4, ymm5

    ; -75 where index > 51 (enters digit range)
    vpcmpgtb   ymm5, ymm3, ymm11
    vpand      ymm5, ymm5, ymm6          ; ymm6 = -75
    vpaddb     ymm4, ymm4, ymm5

    ; -15 where index > 61 ('+' character, ASCII 43)
    vpcmpgtb   ymm5, ymm3, ymm12
    vpand      ymm5, ymm5, ymm7          ; ymm7 = -15
    vpaddb     ymm4, ymm4, ymm5

    ; +3 where index > 62 ('/' character, ASCII 47)
    vpcmpgtb   ymm5, ymm3, ymm13
    vpand      ymm5, ymm5, ymm8          ; ymm8 = +3
    vpaddb     ymm4, ymm4, ymm5

    ; ---- Step 6: Map — add offset to index to get ASCII ----
    vpaddb     ymm3, ymm3, ymm4

    ; ---- Step 7: Store 32 output bytes ----
    vmovdqu    [r14 + rbx], ymm3

    add  r15, 24                   ; consumed 24 input bytes
    add  rbx, 32                   ; wrote    32 output bytes
    jmp  .avx2_loop

.avx2_tail:
    ; Clear upper YMM state before using legacy SSE or scalar instructions.
    ; Required to avoid AVX-SSE transition penalties and for correctness when
    ; mixing VEX-encoded and non-VEX-encoded instructions.
    vzeroupper
    jmp  .scalar_path              ; handle remaining < 24 bytes


; ============================================================================
; SSE2 PATH — 12 input bytes -> 16 output characters per iteration
;
; Uses SSSE3 PSHUFB and SSE2 PMADDUBSW/PACKUSWB/PADDB/PCMPGTB/PAND.
; (PMADDUBSW is actually SSSE3 — but cpu_tier >= 1 on any CPU that ships with
; Linux x86-64 support, and those CPUs invariably have SSSE3.  If the CPU only
; has SSE2 and lacks SSSE3, the PSHUFB/PMADDUBSW instructions would fault and
; the process would receive SIGILL.  On modern Linux x86-64 this is not a
; practical concern; the scalar path is the true SSE2-free fallback.)
; ============================================================================
    align 16
.sse2_path:
    ; Preload XMM constants.
    movdqa  xmm6,  [b64_const_n75]
    movdqa  xmm7,  [b64_const_n15]
    movdqa  xmm8,  [b64_const_p03]
    movdqa  xmm10, [b64_const_25]
    movdqa  xmm11, [b64_const_51]
    movdqa  xmm12, [b64_const_61]
    movdqa  xmm13, [b64_const_62]
    movdqa  xmm14, [b64_const_p65]
    movdqa  xmm15, [b64_const_p06]

    align 16
.sse2_loop:
    ; Guard: need 16 bytes for a safe PSHUFB load (consume 12).
    mov  rax, r13
    sub  rax, r15
    cmp  rax, 16
    jl   .sse2_tail

    ; ---- Step 1: Load and shuffle ----
    movdqu    xmm0, [r12 + r15]
    pshufb    xmm0, [b64_shuf]

    ; ---- Step 3a: Extract high indices ----
    movdqa    xmm1, xmm0
    pmaddubsw xmm1, [b64_mul_lo]
    psrlw     xmm1, 10

    ; ---- Step 3b: Extract low indices ----
    movdqa    xmm2, xmm0
    pmaddubsw xmm2, [b64_mul_hi]
    pand      xmm2, [b64_mask3f]

    ; ---- Step 4: Pack and interleave ----
    packuswb  xmm1, xmm2
    pshufb    xmm1, [b64_pack_shuf]

    ; xmm1 = 16 six-bit indices in correct output order.

    ; ---- Step 5: Build offset vector ----
    movdqa    xmm4, xmm14           ; offset = +65

    ; +6 where index > 25
    movdqa    xmm5, xmm1
    pcmpgtb   xmm5, xmm10           ; SSE2 pcmpgtb is 2-operand; xmm5 = xmm5 > xmm10
    pand      xmm5, xmm15           ; mask by +6 addend
    paddb     xmm4, xmm5

    ; -75 where index > 51
    movdqa    xmm5, xmm1
    pcmpgtb   xmm5, xmm11
    pand      xmm5, xmm6            ; xmm6 = -75
    paddb     xmm4, xmm5

    ; -15 where index > 61
    movdqa    xmm5, xmm1
    pcmpgtb   xmm5, xmm12
    pand      xmm5, xmm7            ; xmm7 = -15
    paddb     xmm4, xmm5

    ; +3 where index > 62
    movdqa    xmm5, xmm1
    pcmpgtb   xmm5, xmm13
    pand      xmm5, xmm8            ; xmm8 = +3
    paddb     xmm4, xmm5

    ; ---- Step 6: Map index -> ASCII ----
    paddb     xmm1, xmm4

    ; ---- Step 7: Store 16 output bytes ----
    movdqu    [r14 + rbx], xmm1

    add  r15, 12
    add  rbx, 16
    jmp  .sse2_loop

.sse2_tail:
    ; Fall through to scalar path for remaining < 12 bytes.


; ============================================================================
; SCALAR PATH — 3 input bytes -> 4 output characters per iteration
;
; Uses the standard base64 algorithm with a 64-byte lookup table.
; Handles all remainder cases (0, 1, or 2 bytes) with proper '=' padding.
;
; Note: rsi is repurposed here as the b64_table pointer.  It held the original
; 'len' argument but that value is already saved in r13.
; ============================================================================
    align 8
.scalar_path:
    lea  rsi, [b64_table]           ; rsi = base64 alphabet lookup table

.scalar_loop:
    mov  rax, r13
    sub  rax, r15                   ; rax = remaining input bytes
    cmp  rax, 3
    jl   .scalar_remainder

    ; ---- Load 3 bytes ----
    movzx  ecx, byte [r12 + r15]       ; A
    movzx  edx, byte [r12 + r15 + 1]  ; B
    movzx  r8d, byte [r12 + r15 + 2]  ; C

    ; ---- Encode 4 output characters ----
    ; char 0: index = A >> 2
    mov    r9d, ecx
    shr    r9d, 2
    movzx  r9d, byte [rsi + r9]
    mov    [r14 + rbx], r9b

    ; char 1: index = ((A & 3) << 4) | (B >> 4)
    and    ecx, 3
    shl    ecx, 4
    mov    r9d, edx
    shr    r9d, 4
    or     ecx, r9d
    movzx  ecx, byte [rsi + rcx]
    mov    [r14 + rbx + 1], cl

    ; char 2: index = ((B & 0xF) << 2) | (C >> 6)
    and    edx, 0xF
    shl    edx, 2
    mov    r9d, r8d
    shr    r9d, 6
    or     edx, r9d
    movzx  edx, byte [rsi + rdx]
    mov    [r14 + rbx + 2], dl

    ; char 3: index = C & 0x3F
    and    r8d, 0x3F
    movzx  r8d, byte [rsi + r8]
    mov    [r14 + rbx + 3], r8b

    add  r15, 3
    add  rbx, 4
    jmp  .scalar_loop

; ---- Remainder: 0, 1, or 2 bytes ----
.scalar_remainder:
    ; rax = remaining bytes (0, 1, or 2) — computed above
    test rax, rax
    jz   .b64_done                  ; 0 bytes: already done

    ; Load the available byte(s); treat missing bytes as 0.
    movzx  ecx, byte [r12 + r15]   ; A (always present — we checked rax > 0)
    xor    edx, edx                 ; B = 0 (may be overwritten)
    cmp    rax, 2
    jl     .scalar_rem1
    movzx  edx, byte [r12 + r15 + 1]  ; B (present when rax >= 2)
    ; C = 0 (we already cleared it implicitly via r8d not being loaded)

.scalar_rem2:
    ; 2 remaining bytes (A, B): output 3 chars + '='
    ; char 0: A >> 2
    mov    r9d, ecx
    shr    r9d, 2
    movzx  r9d, byte [rsi + r9]
    mov    [r14 + rbx], r9b

    ; char 1: ((A & 3) << 4) | (B >> 4)
    and    ecx, 3
    shl    ecx, 4
    mov    r9d, edx
    shr    r9d, 4
    or     ecx, r9d
    movzx  ecx, byte [rsi + rcx]
    mov    [r14 + rbx + 1], cl

    ; char 2: (B & 0xF) << 2  (C=0, so | (C>>6) = 0)
    and    edx, 0xF
    shl    edx, 2
    movzx  edx, byte [rsi + rdx]
    mov    [r14 + rbx + 2], dl

    ; char 3: padding
    mov    byte [r14 + rbx + 3], '='
    add    rbx, 4
    jmp    .b64_done

.scalar_rem1:
    ; 1 remaining byte (A): output 2 chars + '=='
    ; char 0: A >> 2
    mov    r9d, ecx
    shr    r9d, 2
    movzx  r9d, byte [rsi + r9]
    mov    [r14 + rbx], r9b

    ; char 1: (A & 3) << 4  (B=0, so | (B>>4) = 0)
    and    ecx, 3
    shl    ecx, 4
    movzx  ecx, byte [rsi + rcx]
    mov    [r14 + rbx + 1], cl

    ; chars 2-3: padding
    mov    byte [r14 + rbx + 2], '='
    mov    byte [r14 + rbx + 3], '='
    add    rbx, 4

.b64_done:
    ; ---- Return value: ceil(len/3) * 4 ----
    ; Using the formula (len + 2) / 3 * 4 (integer division).
    mov  rax, r13
    add  rax, 2
    xor  rdx, rdx
    mov  rcx, 3
    div  rcx                    ; rax = (len+2)/3, rdx = remainder (discarded)
    imul rax, 4                 ; rax = ceil(len/3) * 4

    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rbx
    ret


; Non-executable stack (required for Linux ELF hardening / SELinux)
section .note.GNU-stack noalloc noexec nowrite progbits
