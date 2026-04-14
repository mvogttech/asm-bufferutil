; ws_cpu.asm — CPU tier, feature bitmask, and cache topology detection
; Exports: cpu_tier (dd), cpu_features (dd), nt_threshold (dq), _init_cpu_features
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
;   bit 5 = AMD vendor (skip vzeroupper — no SSE/AVX transition penalty)
;   bit 6 = VBMI2     (CPUID.7.0:ECX[6], only set when cpu_tier == 3)

BITS 64
DEFAULT REL

section .data
    align 4
    cpu_tier:      dd 0
    cpu_features:  dd 0
    align 8
    nt_threshold:  dq (1 << 23)     ; default 8MB, updated from L3 cache size at init

section .text

global cpu_tier:data hidden
global cpu_features:data hidden
global nt_threshold:data hidden
global _init_cpu_features

; Register allocation across the function:
;   r8d  = XCR0 (from xgetbv)
;   r9d  = max basic leaf (from CPUID leaf 0)
;   r10d = leaf 1 ECX  (OSXSAVE, PCLMULQDQ)
;   r11d = leaf 7 EBX  (AVX2, AVX-512F/BW, BMI2)
;   r12d = leaf 7 ECX  (GFNI, VBMI, VBMI2)  [callee-saved — must push/pop]
;
; Each CPUID leaf is executed exactly once.  The caller-saved scratch
; registers r8-r11 need no push/pop; only r12 (callee-saved) does.

_init_cpu_features:
    push rbx
    push r12

    ; Default = SSE2 baseline
    mov dword [cpu_tier], 1

    ; === Leaf 0: max basic leaf + vendor detection ===
    xor eax, eax
    cpuid
    mov r9d, eax                    ; r9d = max basic leaf

    ; AMD vendor: EBX='Auth' (0x68747541) from "AuthenticAMD"
    cmp ebx, 0x68747541
    jne .not_amd
    or dword [cpu_features], (1 << 5)
.not_amd:

    ; === Leaf 1: OSXSAVE + PCLMULQDQ ===
    mov eax, 1
    cpuid
    mov r10d, ecx                   ; r10d = leaf 1 ECX

    ; === Leaf 7 (if available) — AVX2, AVX-512F/BW, BMI2, GFNI, VBMI, VBMI2 ===
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
    jz .check_vbmi2
    or dword [cpu_features], (1 << 4)

.check_vbmi2:
    ; VBMI2 (bit 6): leaf 7 ECX bit 6 — only useful when cpu_tier == 3
    cmp dword [cpu_tier], 3
    jl .check_bmi2
    test r12d, (1 << 6)
    jz .check_bmi2
    or dword [cpu_features], (1 << 6)

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
    jl .detect_cache
    mov eax, 0x80000001
    cpuid
    test ecx, (1 << 5)
    jz .detect_cache
    or dword [cpu_features], 8

.detect_cache:
    ; === Cache topology: detect L3 size, set nt_threshold to 50% of L3 ===
    ; AMD uses leaf 0x8000001D, Intel uses leaf 0x04 — same field layout.
    xor r8, r8                      ; r8 = largest cache size found

    test dword [cpu_features], (1 << 5)
    jz .cache_intel

    ; AMD: check extended leaf 0x8000001D is available
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x8000001D
    jb .cache_set_threshold
    mov r9d, 0x8000001D
    jmp .cache_iterate

.cache_intel:
    ; Intel: check basic leaf 0x04 is available
    xor eax, eax
    cpuid
    cmp eax, 4
    jb .cache_set_threshold
    mov r9d, 4

.cache_iterate:
    xor r10d, r10d                  ; r10d = subleaf index

.cache_loop:
    mov eax, r9d
    mov ecx, r10d
    cpuid

    ; EAX[4:0] = cache type (0 = no more caches)
    test eax, 0x1F
    jz .cache_set_threshold

    ; size = (Ways+1) * (Partitions+1) * (LineSize+1) * (Sets+1)
    mov edi, ecx
    inc edi                         ; edi = Sets+1

    mov eax, ebx
    shr eax, 22
    inc eax                         ; eax = Ways+1

    mov ecx, ebx
    shr ecx, 12
    and ecx, 0x3FF
    inc ecx                         ; ecx = Partitions+1

    and ebx, 0xFFF
    inc ebx                         ; ebx = LineSize+1

    imul eax, ecx                   ; Ways * Partitions
    imul eax, ebx                   ; Ways * Partitions * LineSize
    mov ecx, eax
    imul rcx, rdi                   ; 64-bit: * Sets → total cache size

    cmp rcx, r8
    jbe .cache_next
    mov r8, rcx                     ; new max

.cache_next:
    inc r10d
    jmp .cache_loop

.cache_set_threshold:
    test r8, r8
    jz .all_done                    ; no cache detected, keep 8MB default
    shr r8, 1                       ; 50% of largest cache

    cmp r8, (1 << 23)
    jb .all_done                    ; below 8MB floor, keep default
    mov [nt_threshold], r8

.all_done:
    pop r12
    pop rbx
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
