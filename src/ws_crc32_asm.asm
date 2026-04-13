; ws_crc32_asm.asm — CRC-32/ISO-HDLC using SSE4.2 CRC32 instruction
;
; C signature:
;   uint32_t ws_crc32(const uint8_t *buf, size_t len, uint32_t init);
;
; Usage convention (CRC-32/ISO-HDLC / CRC-32b):
;   First call:  init = 0xFFFFFFFF
;   Final value: result XOR 0xFFFFFFFF
;   Chaining:    pass previous return value as init for next call
;
; Register map:
;   rdi = buf pointer
;   rsi = len
;   edx = init (32-bit accumulator)
;   eax = return value (updated accumulator, NOT yet XOR'd)
;
; No CPUID guard needed — SSE4.2 CRC32 is guaranteed on any machine
; where cpu_tier >= 1 (i.e., it passes the SSE2 check in ws_cpu.asm,
; which all modern x86-64 CPUs support; CRC32 was added in Nehalem 2008).

BITS 64
DEFAULT REL

section .text

global ws_crc32

; ============================================================================
; ws_crc32(const uint8_t *buf, size_t len, uint32_t init) -> uint32_t
; ============================================================================
ws_crc32:
    mov eax, edx                ; accumulator = init (already pre-inverted by caller)
    test rsi, rsi
    jz  .done

    ; --- Main loop: 8 bytes per iteration ---
    ; CRC32 r64, m64 has 3-cycle latency, 1-cycle throughput on Golden Cove
    mov rcx, rsi
    shr rcx, 3                  ; rcx = number of 8-byte chunks
    test rcx, rcx
    jz  .tail

    align 16
.qword_loop:
    crc32 rax, qword [rdi]
    add   rdi, 8
    dec   rcx
    jnz   .qword_loop

.tail:
    ; Handle remaining 0–7 bytes one at a time
    and   rsi, 7
    jz    .done

    align 8
.byte_loop:
    crc32 eax, byte [rdi]
    inc   rdi
    dec   rsi
    jnz   .byte_loop

.done:
    ; Return accumulator — caller XORs with 0xFFFFFFFF for final CRC value
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
