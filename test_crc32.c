/* test_crc32.c — standalone correctness test for ws_crc32
 *
 * Compile on Linux:
 *   nasm -f elf64 ws_crc32_asm.asm -o ws_crc32_asm.o
 *   gcc -O2 test_crc32.c ws_crc32_asm.o -o test_crc32
 * Run:
 *   ./test_crc32
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern uint32_t ws_crc32(const uint8_t *buf, size_t len, uint32_t init);

int main(void) {
    int failures = 0;

    /* CRC-32/ISO-HDLC of "123456789" = 0xCBF43926 (standard check vector) */
    const uint8_t *msg = (const uint8_t *)"123456789";
    uint32_t crc = ws_crc32(msg, 9, 0xFFFFFFFF) ^ 0xFFFFFFFF;
    if (crc != 0xCBF43926U) {
        printf("FAIL: CRC32(\"123456789\") = 0x%08X, want 0xCBF43926\n", crc);
        failures++;
    } else {
        printf("PASS: CRC32(\"123456789\") = 0xCBF43926\n");
    }

    /* Empty string: result = 0x00000000 */
    crc = ws_crc32(NULL, 0, 0xFFFFFFFF) ^ 0xFFFFFFFF;
    if (crc != 0x00000000U) {
        printf("FAIL: CRC32(\"\") = 0x%08X, want 0x00000000\n", crc);
        failures++;
    } else {
        printf("PASS: CRC32(\"\") = 0x00000000\n");
    }

    /* Chaining: CRC32("12345") then CRC32("6789") == CRC32("123456789") */
    uint32_t acc = 0xFFFFFFFF;
    acc = ws_crc32(msg,     5, acc);   /* "12345" */
    acc = ws_crc32(msg + 5, 4, acc);   /* "6789"  */
    crc = acc ^ 0xFFFFFFFF;
    if (crc != 0xCBF43926U) {
        printf("FAIL: chained CRC32 = 0x%08X, want 0xCBF43926\n", crc);
        failures++;
    } else {
        printf("PASS: chained CRC32 = 0xCBF43926\n");
    }

    return failures;
}
