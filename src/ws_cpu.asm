; ws_cpu.asm — CPU tier and feature bitmask detection
; Exports: cpu_tier (dd), cpu_features (dd), _init_cpu_features
;
; cpu_tier values:
;   0 = scalar only
;   1 = SSE2 baseline
;   2 = AVX2
;   3 = AVX-512F+BW (disabled on production Alder Lake)
;
; cpu_features bitmask:
;   bit 0 = GFNI      (CPUID.7.0:ECX[8])
;   bit 1 = PCLMULQDQ (CPUID.1:ECX[1])
;   bit 2 = BMI2      (CPUID.7.0:EBX[8])
;   bit 3 = LZCNT     (CPUID.0x80000001:ECX[5])

BITS 64
DEFAULT REL

section .data
    align 4
    cpu_tier:     dd 0
    cpu_features: dd 0

section .text

global cpu_tier
global cpu_features
global _init_cpu_features

_init_cpu_features:
    push rbx

    ; --- Tier detection ---
    mov dword [cpu_tier], 1         ; SSE2 baseline

    xor eax, eax
    cpuid
    cmp eax, 7
    jl .feat_detect

    mov eax, 1
    cpuid
    test ecx, (1 << 27)             ; OSXSAVE
    jz .feat_detect

    xor ecx, ecx
    xgetbv
    mov r8d, eax
    and eax, 0x06
    cmp eax, 0x06                   ; YMM state saved by OS
    jne .feat_detect

    mov eax, 7
    xor ecx, ecx
    cpuid
    test ebx, (1 << 5)              ; AVX2
    jz .feat_detect
    mov dword [cpu_tier], 2

    mov eax, r8d
    and eax, 0xE0
    cmp eax, 0xE0                   ; ZMM/opmask state saved by OS
    jne .feat_detect
    test ebx, (1 << 16)             ; AVX-512F
    jz .feat_detect
    test ebx, (1 << 30)             ; AVX-512BW
    jz .feat_detect
    mov dword [cpu_tier], 3

    ; --- Feature bitmask detection ---
    ; (runs regardless of tier — these features are orthogonal)
.feat_detect:
    xor eax, eax
    cpuid
    cmp eax, 7
    jl .check_pclmul

    mov eax, 7
    xor ecx, ecx
    cpuid

    ; GFNI: leaf 7 ECX bit 8
    test ecx, (1 << 8)
    jz .check_bmi2
    or dword [cpu_features], 1

.check_bmi2:
    ; BMI2: leaf 7 EBX bit 8
    test ebx, (1 << 8)
    jz .check_pclmul
    or dword [cpu_features], 4

.check_pclmul:
    ; PCLMULQDQ: leaf 1 ECX bit 1
    mov eax, 1
    cpuid
    test ecx, (1 << 1)
    jz .check_lzcnt
    or dword [cpu_features], 2

.check_lzcnt:
    ; LZCNT: extended leaf 0x80000001 ECX bit 5
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
    pop rbx
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
