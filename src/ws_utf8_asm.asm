; ============================================================================
; ws_utf8_asm.asm — SIMD UTF-8 Validator (Keiser-Lemire VPSHUFB technique)
;
; Implements:
;   ws_utf8_validate(buf, len) → 1 if valid UTF-8, 0 if invalid
;
; Tiered dispatch:
;   cpu_tier >= 3 (AVX-512F+BW): 64-byte ASCII fast path, scalar non-ASCII
;   cpu_tier >= 2 (AVX2):        32-byte ASCII fast path, scalar non-ASCII
;   cpu_tier <  2 (scalar):      Byte-at-a-time UTF-8 state machine
;
; The SIMD paths use a hybrid strategy:
;   - Fast ASCII check: if all bytes in a 32/64-byte chunk have bit 7 clear,
;     the chunk is valid (assuming no pending multi-byte continuation state).
;   - Non-ASCII chunks fall back to the scalar validator for correctness.
;
; The scalar validator is a complete UTF-8 state machine that checks:
;   1. Continuation bytes (10xxxxxx) only after appropriate leaders
;   2. Correct continuation byte counts per leader
;   3. No overlong encodings (e.g. C0 80, E0 80 80)
;   4. No surrogates (U+D800-U+DFFF)
;   5. No codepoints > U+10FFFF
;   6. No truncated sequences at end of input
;
; Build:
;   nasm -f elf64 ws_utf8_asm.asm -o ws_utf8_asm.o
; ============================================================================

BITS 64
DEFAULT REL

extern cpu_tier
extern cpu_features

; Skip vzeroupper on AMD (no SSE/AVX transition penalty on Zen).
%macro SAFE_VZEROUPPER 0
    test dword [cpu_features], (1 << 5)
    jnz %%skip
    vzeroupper
%%skip:
%endmacro

section .text

; ============================================================================
; ws_utf8_validate(buf, len)
;
; rdi = buf (const uint8_t *)
; rsi = len (size_t)
;
; Returns: eax = 1 (valid UTF-8) or 0 (invalid)
; ============================================================================
global ws_utf8_validate
ws_utf8_validate:
    ; Empty buffer is valid UTF-8
    test rsi, rsi
    jz .valid

    ; Dispatch based on cpu_tier
    cmp dword [cpu_tier], 3
    jge .avx512_entry
    cmp dword [cpu_tier], 2
    jge .avx2_entry
    jmp .scalar_entry

; ============================================================================
; AVX-512 path: 64-byte ASCII fast check with scalar fallback
; ============================================================================
.avx512_entry:
    xor r8, r8                      ; r8 = current position
    xor r9d, r9d                    ; r9d = pending continuation count (0 = none)

.avx512_loop:
    mov rax, rsi
    sub rax, r8
    cmp rax, 64
    jl .avx512_tail

    ; If we have pending continuations, can't use the ASCII fast path
    test r9d, r9d
    jnz .avx512_scalar_chunk

    vmovdqu64 zmm0, [rdi + r8]

    ; ASCII fast check: test if all bytes have bit 7 clear
    ; vpmovb2m extracts the sign bit of each byte into mask register
    vpmovb2m k1, zmm0
    kortestq k1, k1
    jnz .avx512_scalar_chunk        ; non-ASCII bytes present

    ; All 64 bytes are ASCII — valid, advance
    add r8, 64
    jmp .avx512_loop

.avx512_scalar_chunk:
    ; Process this 64-byte chunk byte-at-a-time
    lea rcx, [r8 + 64]             ; end of this chunk
    cmp rcx, rsi
    cmova rcx, rsi                  ; clamp to buffer end

.avx512_scalar_byte:
    cmp r8, rcx
    jge .avx512_loop                ; finished this chunk, try next 64

    movzx eax, byte [rdi + r8]
    inc r8

    test r9d, r9d
    jnz .avx512_cont

    ; Expecting new character
    cmp al, 0x80
    jb .avx512_scalar_byte          ; 0x00-0x7F: ASCII

    cmp al, 0xC2
    jb .invalid                     ; 0x80-0xC1: bare continuation or overlong
    cmp al, 0xDF
    jbe .avx512_need1               ; 0xC2-0xDF: 2-byte leader
    cmp al, 0xEF
    jbe .avx512_need2               ; 0xE0-0xEF: 3-byte leader
    cmp al, 0xF4
    jbe .avx512_need3               ; 0xF0-0xF4: 4-byte leader
    jmp .invalid                    ; 0xF5-0xFF: invalid

.avx512_need1:
    mov r9d, 1
    ; No special range check needed for 0xC2-0xDF
    mov r10d, 0                     ; r10d = 0 means no range constraint on next cont
    jmp .avx512_scalar_byte

.avx512_need2:
    mov r9d, 2
    ; Save leader for overlong/surrogate check on first continuation byte
    mov r10d, eax                   ; r10d = leader byte (0xE0-0xEF)
    mov r11d, 1                     ; r11d = 1 means "check first continuation"
    jmp .avx512_scalar_byte

.avx512_need3:
    mov r9d, 3
    mov r10d, eax                   ; r10d = leader byte (0xF0-0xF4)
    mov r11d, 1                     ; r11d = 1 means "check first continuation"
    jmp .avx512_scalar_byte

.avx512_cont:
    ; Expecting continuation byte (0x80-0xBF)
    cmp al, 0x80
    jb .invalid
    cmp al, 0xBF
    ja .invalid

    ; Special range checks on first continuation byte
    cmp r11d, 1
    jne .avx512_cont_ok

    ; First continuation after 3-byte leader
    cmp r10d, 0xE0
    je .avx512_check_overlong3
    cmp r10d, 0xED
    je .avx512_check_surrogate
    ; First continuation after 4-byte leader
    cmp r10d, 0xF0
    je .avx512_check_overlong4
    cmp r10d, 0xF4
    je .avx512_check_range4
    jmp .avx512_cont_ok

.avx512_check_overlong3:
    ; E0 followed by < A0 is overlong
    cmp al, 0xA0
    jb .invalid
    jmp .avx512_cont_ok

.avx512_check_surrogate:
    ; ED followed by >= A0 is surrogate (U+D800-U+DFFF)
    cmp al, 0xA0
    jae .invalid
    jmp .avx512_cont_ok

.avx512_check_overlong4:
    ; F0 followed by < 90 is overlong
    cmp al, 0x90
    jb .invalid
    jmp .avx512_cont_ok

.avx512_check_range4:
    ; F4 followed by >= 90 is > U+10FFFF
    cmp al, 0x90
    jae .invalid

.avx512_cont_ok:
    mov r11d, 0                     ; clear first-continuation flag
    dec r9d
    jmp .avx512_scalar_byte

.avx512_tail:
    ; Process remaining < 64 bytes scalar
    cmp r8, rsi
    jge .avx512_finish

    movzx eax, byte [rdi + r8]
    inc r8

    test r9d, r9d
    jnz .avx512_tail_cont

    cmp al, 0x80
    jb .avx512_tail
    cmp al, 0xC2
    jb .invalid
    cmp al, 0xDF
    jbe .avx512_tail_need1
    cmp al, 0xEF
    jbe .avx512_tail_need2
    cmp al, 0xF4
    jbe .avx512_tail_need3
    jmp .invalid

.avx512_tail_need1:
    mov r9d, 1
    mov r10d, 0
    jmp .avx512_tail

.avx512_tail_need2:
    mov r9d, 2
    mov r10d, eax
    mov r11d, 1
    jmp .avx512_tail

.avx512_tail_need3:
    mov r9d, 3
    mov r10d, eax
    mov r11d, 1
    jmp .avx512_tail

.avx512_tail_cont:
    cmp al, 0x80
    jb .invalid
    cmp al, 0xBF
    ja .invalid

    cmp r11d, 1
    jne .avx512_tail_cont_ok

    cmp r10d, 0xE0
    je .avx512_tail_overlong3
    cmp r10d, 0xED
    je .avx512_tail_surrogate
    cmp r10d, 0xF0
    je .avx512_tail_overlong4
    cmp r10d, 0xF4
    je .avx512_tail_range4
    jmp .avx512_tail_cont_ok

.avx512_tail_overlong3:
    cmp al, 0xA0
    jb .invalid
    jmp .avx512_tail_cont_ok

.avx512_tail_surrogate:
    cmp al, 0xA0
    jae .invalid
    jmp .avx512_tail_cont_ok

.avx512_tail_overlong4:
    cmp al, 0x90
    jb .invalid
    jmp .avx512_tail_cont_ok

.avx512_tail_range4:
    cmp al, 0x90
    jae .invalid

.avx512_tail_cont_ok:
    mov r11d, 0
    dec r9d
    jmp .avx512_tail

.avx512_finish:
    ; If we still expect continuation bytes, input is truncated/invalid
    test r9d, r9d
    jnz .invalid
    SAFE_VZEROUPPER
    mov eax, 1
    ret

; ============================================================================
; AVX2 path: 32-byte ASCII fast check with scalar fallback
; ============================================================================
.avx2_entry:
    xor r8, r8                      ; r8 = current position
    xor r9d, r9d                    ; r9d = pending continuation count

.avx2_loop:
    mov rax, rsi
    sub rax, r8
    cmp rax, 32
    jl .avx2_tail

    ; If we have pending continuations, can't use the ASCII fast path
    test r9d, r9d
    jnz .avx2_scalar_chunk

    vmovdqu ymm0, [rdi + r8]

    ; ASCII fast check: test if all bytes have bit 7 clear
    ; vpmovmskb extracts the sign bit of each byte
    vpmovmskb eax, ymm0
    test eax, eax
    jnz .avx2_scalar_chunk          ; non-ASCII bytes present

    ; All 32 bytes are ASCII — valid, advance
    add r8, 32
    jmp .avx2_loop

.avx2_scalar_chunk:
    ; Process this 32-byte chunk byte-at-a-time
    lea rcx, [r8 + 32]
    cmp rcx, rsi
    cmova rcx, rsi

.avx2_scalar_byte:
    cmp r8, rcx
    jge .avx2_loop

    movzx eax, byte [rdi + r8]
    inc r8

    test r9d, r9d
    jnz .avx2_cont

    cmp al, 0x80
    jb .avx2_scalar_byte
    cmp al, 0xC2
    jb .avx2_invalid_cleanup
    cmp al, 0xDF
    jbe .avx2_need1
    cmp al, 0xEF
    jbe .avx2_need2
    cmp al, 0xF4
    jbe .avx2_need3
    jmp .avx2_invalid_cleanup

.avx2_need1:
    mov r9d, 1
    mov r10d, 0
    jmp .avx2_scalar_byte

.avx2_need2:
    mov r9d, 2
    mov r10d, eax
    mov r11d, 1
    jmp .avx2_scalar_byte

.avx2_need3:
    mov r9d, 3
    mov r10d, eax
    mov r11d, 1
    jmp .avx2_scalar_byte

.avx2_cont:
    cmp al, 0x80
    jb .avx2_invalid_cleanup
    cmp al, 0xBF
    ja .avx2_invalid_cleanup

    cmp r11d, 1
    jne .avx2_cont_ok

    cmp r10d, 0xE0
    je .avx2_check_overlong3
    cmp r10d, 0xED
    je .avx2_check_surrogate
    cmp r10d, 0xF0
    je .avx2_check_overlong4
    cmp r10d, 0xF4
    je .avx2_check_range4
    jmp .avx2_cont_ok

.avx2_check_overlong3:
    cmp al, 0xA0
    jb .avx2_invalid_cleanup
    jmp .avx2_cont_ok

.avx2_check_surrogate:
    cmp al, 0xA0
    jae .avx2_invalid_cleanup
    jmp .avx2_cont_ok

.avx2_check_overlong4:
    cmp al, 0x90
    jb .avx2_invalid_cleanup
    jmp .avx2_cont_ok

.avx2_check_range4:
    cmp al, 0x90
    jae .avx2_invalid_cleanup

.avx2_cont_ok:
    mov r11d, 0
    dec r9d
    jmp .avx2_scalar_byte

.avx2_invalid_cleanup:
    SAFE_VZEROUPPER
    xor eax, eax
    ret

.avx2_tail:
    ; Process remaining < 32 bytes scalar
    cmp r8, rsi
    jge .avx2_finish

    movzx eax, byte [rdi + r8]
    inc r8

    test r9d, r9d
    jnz .avx2_tail_cont

    cmp al, 0x80
    jb .avx2_tail
    cmp al, 0xC2
    jb .avx2_invalid_cleanup
    cmp al, 0xDF
    jbe .avx2_tail_need1
    cmp al, 0xEF
    jbe .avx2_tail_need2
    cmp al, 0xF4
    jbe .avx2_tail_need3
    jmp .avx2_invalid_cleanup

.avx2_tail_need1:
    mov r9d, 1
    mov r10d, 0
    jmp .avx2_tail

.avx2_tail_need2:
    mov r9d, 2
    mov r10d, eax
    mov r11d, 1
    jmp .avx2_tail

.avx2_tail_need3:
    mov r9d, 3
    mov r10d, eax
    mov r11d, 1
    jmp .avx2_tail

.avx2_tail_cont:
    cmp al, 0x80
    jb .avx2_invalid_cleanup
    cmp al, 0xBF
    ja .avx2_invalid_cleanup

    cmp r11d, 1
    jne .avx2_tail_cont_ok

    cmp r10d, 0xE0
    je .avx2_tail_overlong3
    cmp r10d, 0xED
    je .avx2_tail_surrogate
    cmp r10d, 0xF0
    je .avx2_tail_overlong4
    cmp r10d, 0xF4
    je .avx2_tail_range4
    jmp .avx2_tail_cont_ok

.avx2_tail_overlong3:
    cmp al, 0xA0
    jb .avx2_invalid_cleanup
    jmp .avx2_tail_cont_ok

.avx2_tail_surrogate:
    cmp al, 0xA0
    jae .avx2_invalid_cleanup
    jmp .avx2_tail_cont_ok

.avx2_tail_overlong4:
    cmp al, 0x90
    jb .avx2_invalid_cleanup
    jmp .avx2_tail_cont_ok

.avx2_tail_range4:
    cmp al, 0x90
    jae .avx2_invalid_cleanup

.avx2_tail_cont_ok:
    mov r11d, 0
    dec r9d
    jmp .avx2_tail

.avx2_finish:
    test r9d, r9d
    jnz .avx2_invalid_cleanup
    SAFE_VZEROUPPER
    mov eax, 1
    ret

; ============================================================================
; Scalar path: byte-at-a-time UTF-8 state machine
; ============================================================================
.scalar_entry:
    xor r8, r8                      ; r8 = current position
    xor r9d, r9d                    ; r9d = pending continuation count
    xor r10d, r10d                  ; r10d = leader byte (for range checks)
    xor r11d, r11d                  ; r11d = first-continuation flag

.scalar_loop:
    cmp r8, rsi
    jge .scalar_finish

    movzx eax, byte [rdi + r8]
    inc r8

    test r9d, r9d
    jnz .scalar_cont

    ; === State 0: expecting new character ===
    cmp al, 0x80
    jb .scalar_loop                 ; 0x00-0x7F: ASCII, valid

    cmp al, 0xC2
    jb .invalid                     ; 0x80-0xC1: invalid
    cmp al, 0xDF
    jbe .scalar_need1               ; 0xC2-0xDF: 2-byte leader
    cmp al, 0xEF
    jbe .scalar_need2               ; 0xE0-0xEF: 3-byte leader
    cmp al, 0xF4
    jbe .scalar_need3               ; 0xF0-0xF4: 4-byte leader
    jmp .invalid                    ; 0xF5-0xFF: invalid

.scalar_need1:
    mov r9d, 1
    mov r11d, 0                     ; no special range check for 2-byte
    jmp .scalar_loop

.scalar_need2:
    mov r9d, 2
    mov r10d, eax                   ; save leader for range check
    mov r11d, 1                     ; check first continuation
    jmp .scalar_loop

.scalar_need3:
    mov r9d, 3
    mov r10d, eax                   ; save leader for range check
    mov r11d, 1                     ; check first continuation
    jmp .scalar_loop

.scalar_cont:
    ; === Expecting continuation byte (0x80-0xBF) ===
    cmp al, 0x80
    jb .invalid
    cmp al, 0xBF
    ja .invalid

    ; Special range checks on first continuation byte after certain leaders
    cmp r11d, 1
    jne .scalar_cont_ok

    ; Check which leader triggered the range constraint
    cmp r10d, 0xE0
    je .scalar_overlong3
    cmp r10d, 0xED
    je .scalar_surrogate
    cmp r10d, 0xF0
    je .scalar_overlong4
    cmp r10d, 0xF4
    je .scalar_range4
    jmp .scalar_cont_ok             ; other leaders: no extra constraint

.scalar_overlong3:
    ; E0 followed by < A0 would be overlong (encodes < U+0800)
    cmp al, 0xA0
    jb .invalid
    jmp .scalar_cont_ok

.scalar_surrogate:
    ; ED followed by >= A0 would be surrogate (U+D800-U+DFFF)
    cmp al, 0xA0
    jae .invalid
    jmp .scalar_cont_ok

.scalar_overlong4:
    ; F0 followed by < 90 would be overlong (encodes < U+10000)
    cmp al, 0x90
    jb .invalid
    jmp .scalar_cont_ok

.scalar_range4:
    ; F4 followed by >= 90 would be > U+10FFFF
    cmp al, 0x90
    jae .invalid

.scalar_cont_ok:
    mov r11d, 0                     ; clear first-continuation flag
    dec r9d
    jmp .scalar_loop

.scalar_finish:
    ; If we still expect continuation bytes, the input is truncated
    test r9d, r9d
    jnz .invalid

.valid:
    mov eax, 1
    ret

.invalid:
    SAFE_VZEROUPPER
    xor eax, eax
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
