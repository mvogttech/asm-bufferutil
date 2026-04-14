/* test_crc32.c — standalone correctness test for ws_crc32
 *
 * The x86 CRC32 instruction computes CRC-32C (Castagnoli, polynomial 0x1EDC6F41),
 * NOT standard CRC-32/ISO-HDLC. Check values use the CRC-32C standard.
 *
 * Compile on Linux:
 *   nasm -f elf64 src/ws_cpu.asm -o ws_cpu.o
 *   nasm -f elf64 src/ws_crc32_asm.asm -o ws_crc32_asm.o
 *   gcc -O2 test/crc32.c ws_cpu.o ws_crc32_asm.o -o test_crc32
 * Run:
 *   ./test_crc32
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

extern uint32_t ws_crc32(const uint8_t *buf, size_t len, uint32_t init);
extern void _init_cpu_features(void);

/* Reference serial CRC-32C using the x86 CRC32 instruction.
 * This provides a known-good baseline to compare against the
 * PCLMULQDQ folding path for large buffers. */
static uint32_t crc32c_serial(const uint8_t *buf, size_t len, uint32_t init) {
    uint64_t acc = init;
    while (len >= 8) {
        uint64_t v;
        memcpy(&v, buf, 8);
        __asm__ __volatile__("crc32q %1, %0" : "+r"(acc) : "r"(v));
        buf += 8;
        len -= 8;
    }
    while (len > 0) {
        __asm__ __volatile__("crc32b %1, %0" : "+r"(acc) : "r"((uint64_t)*buf));
        buf++;
        len--;
    }
    return (uint32_t)acc;
}

int main(void) {
    int failures = 0;
    uint32_t crc;

    /* Initialise CPU feature detection (needed for PCLMULQDQ dispatch) */
    _init_cpu_features();

    /* CRC-32C of "123456789" = 0xE3069283 (Castagnoli check vector) */
    const uint8_t *msg = (const uint8_t *)"123456789";
    crc = ws_crc32(msg, 9, 0xFFFFFFFF) ^ 0xFFFFFFFF;
    if (crc != 0xE3069283U) {
        printf("FAIL: CRC32C(\"123456789\") = 0x%08X, want 0xE3069283\n", crc);
        failures++;
    } else {
        printf("PASS: CRC32C(\"123456789\") = 0xE3069283\n");
    }

    /* Empty string: result = 0x00000000 */
    crc = ws_crc32(NULL, 0, 0xFFFFFFFF) ^ 0xFFFFFFFF;
    if (crc != 0x00000000U) {
        printf("FAIL: CRC32C(\"\") = 0x%08X, want 0x00000000\n", crc);
        failures++;
    } else {
        printf("PASS: CRC32C(\"\") = 0x00000000\n");
    }

    /* Chaining: CRC32C("12345") then CRC32C("6789") == CRC32C("123456789") */
    uint32_t acc = 0xFFFFFFFF;
    acc = ws_crc32(msg,     5, acc);   /* "12345" */
    acc = ws_crc32(msg + 5, 4, acc);   /* "6789"  */
    crc = acc ^ 0xFFFFFFFF;
    if (crc != 0xE3069283U) {
        printf("FAIL: chained CRC32C = 0x%08X, want 0xE3069283\n", crc);
        failures++;
    } else {
        printf("PASS: chained CRC32C = 0xE3069283\n");
    }

    /* Large buffer test (exercises PCLMULQDQ path for len >= 256) */
    printf("\nPCLMULQDQ path tests (large buffers):\n");

    size_t test_sizes[] = {256, 300, 512, 1000, 1024, 4096, 8192, 65536};
    int num_sizes = sizeof(test_sizes) / sizeof(test_sizes[0]);

    for (int t = 0; t < num_sizes; t++) {
        size_t sz = test_sizes[t];
        uint8_t *buf = (uint8_t *)malloc(sz);
        if (!buf) {
            printf("FAIL: malloc(%zu) failed\n", sz);
            failures++;
            continue;
        }

        /* Fill with deterministic pseudo-random data */
        for (size_t i = 0; i < sz; i++)
            buf[i] = (uint8_t)(i * 0x9E3779B9U >> 24);

        /* Compute CRC with serial reference */
        uint32_t expected = crc32c_serial(buf, sz, 0xFFFFFFFF);

        /* Compute CRC with ws_crc32 (may use PCLMULQDQ for sz >= 256) */
        uint32_t got = ws_crc32(buf, sz, 0xFFFFFFFF);

        if (got != expected) {
            printf("FAIL: size=%zu: got=0x%08X, want=0x%08X\n", sz, got, expected);
            failures++;
        } else {
            printf("PASS: size=%zu: CRC=0x%08X\n", sz, got);
        }

        /* Also test chained: split at midpoint */
        size_t mid = sz / 2;
        uint32_t chain = ws_crc32(buf, mid, 0xFFFFFFFF);
        chain = ws_crc32(buf + mid, sz - mid, chain);
        if (chain != expected) {
            printf("FAIL: chained size=%zu: got=0x%08X, want=0x%08X\n", sz, chain, expected);
            failures++;
        } else {
            printf("PASS: chained size=%zu: CRC=0x%08X\n", sz, chain);
        }

        free(buf);
    }

    printf("\n%d passed, %d failed\n", failures == 0 ? (3 + num_sizes * 2) : -1, failures);
    return failures;
}
