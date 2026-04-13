; ws_cpu.asm — CPU tier and feature bitmask detection
; Exports: cpu_tier (dd), cpu_features (dd), _init_cpu_features
;
; cpu_tier values:
;   0 = scalar only
;   1 = SSE2 baseline
;   2 = AVX2
;   3 = AVX-512F+BW
;
; cpu_features bitmask:
;   bit 0 = GFNI      (CPUID.7.0:ECX[8])
;   bit 1 = PCLMULQDQ (CPUID.1:ECX[1])
;   bit 2 = BMI2      (CPUID.7.0:EBX[8])
;   bit 3 = LZCNT     (CPUID.0x80000001:ECX[5])
;   bit 4 = VBMI      (CPUID.7.0:ECX[1], only set when cpu_tier == 3)

BITS 64
DEFAULT REL

section .data
    align 4
    cpu_tier:     dd 0
    cpu_features: dd 0

section .text

global cpu_tier:data hidden
global cpu_features:data hidden
global _init_cpu_features

; Register allocation across the function:
;   r8d  = XCR0 (from xgetbv)
;   r9d  = max basic leaf (from CPUID leaf 0)
;   r10d = leaf 1 ECX  (OSXSAVE, PCLMULQDQ)
;   r11d = leaf 7 EBX  (AVX2, AVX-512F/BW, BMI2)
;   r12d = leaf 7 ECX  (GFNI, VBMI)   [callee-saved — must push/pop]
;
; Each CPUID leaf is executed exactly once.  The caller-saved scratch
; registers r8-r11 need no push/pop; only r12 (callee-saved) does.

_init_cpu_features:
    push rbx
    push r12

    ; Default = SSE2 baseline
    mov dword [cpu_tier], 1

    ; === Leaf 0: max basic leaf ===
    xor eax, eax
    cpuid
    mov r9d, eax                    ; r9d = max basic leaf

    ; === Leaf 1: OSXSAVE + PCLMULQDQ ===
    mov eax, 1
    cpuid
    mov r10d, ecx                   ; r10d = leaf 1 ECX

    ; === Leaf 7 (if available) — AVX2, AVX-512F/BW, BMI2, GFNI, VBMI ===
    cmp r9d, 7
    jb .no_leaf7
    mov eax, 7
    xor ecx, ecx
    cpuid
    mov r11d, ebx                   ; r11d = leaf 7 EBX
    mov r12d, ecx                   ; r12d = leaf 7 ECX
.no_leaf7:

    ; === Tier detection (AVX2 / AVX-512) ===
    test r10d, (1 << 27)            ; OSXSAVE?
    jz .feat_detect

    xor ecx, ecx
    xgetbv
    mov r8d, eax                    ; r8d = XCR0

    and eax, 0x06
    cmp eax, 0x06                   ; YMM state saved by OS?
    jne .feat_detect

    cmp r9d, 7
    jb .feat_detect
    test r11d, (1 << 5)             ; AVX2?
    jz .feat_detect
    mov dword [cpu_tier], 2

    mov eax, r8d
    and eax, 0xE0
    cmp eax, 0xE0                   ; ZMM/opmask state saved by OS?
    jne .feat_detect
    test r11d, (1 << 16)            ; AVX-512F?
    jz .feat_detect
    test r11d, (1 << 30)            ; AVX-512BW?
    jz .feat_detect
    mov dword [cpu_tier], 3

.feat_detect:
    ; === Feature bitmask (all use cached leaf results — no further CPUID) ===
    cmp r9d, 7
    jb .check_pclmul

    ; GFNI (bit 0): leaf 7 ECX bit 8
    test r12d, (1 << 8)
    jz .check_vbmi
    or dword [cpu_features], 1

.check_vbmi:
    ; VBMI (bit 4): leaf 7 ECX bit 1 — only useful when cpu_tier == 3
    cmp dword [cpu_tier], 3
    jl .check_bmi2
    test r12d, (1 << 1)
    jz .check_bmi2
    or dword [cpu_features], (1 << 4)

.check_bmi2:
    ; BMI2 (bit 2): leaf 7 EBX bit 8
    test r11d, (1 << 8)
    jz .check_pclmul
    or dword [cpu_features], 4

.check_pclmul:
    ; PCLMULQDQ (bit 1): leaf 1 ECX bit 1 (cached — no re-execution)
    test r10d, (1 << 1)
    jz .check_lzcnt
    or dword [cpu_features], 2

.check_lzcnt:
    ; LZCNT (bit 3): extended leaf 0x80000001 ECX bit 5
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000001
    jl .all_done
    mov eax, 0x80000001
    cpuid
    test ecx, (1 << 5)
    jz .all_done
    or dword [cpu_features], 8

.all_done:
    pop r12
    pop rbx
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
