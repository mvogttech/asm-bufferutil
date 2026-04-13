# Contributing to asm-bufferutil

## Prerequisites

Native development requires a Linux x86-64 environment. The SIMD assembly paths only build and run on Linux x86-64. All other platforms use the pure JavaScript fallback.

| Tool | Version | Notes |
|---|---|---|
| Node.js | ≥ 16 | |
| NASM | any recent | `sudo apt install nasm` on Debian/Ubuntu |
| node-gyp | bundled | via `npm ci` |
| Python | 3.x | required by node-gyp |
| gcc | any recent | required by node-gyp |

On Windows/macOS you can run tests against the JS fallback without NASM.

## Build & Test

```bash
# Install and build the native addon
npm ci

# Run the test suite
npm test

# Run benchmarks
npm run bench
```

## Assembly Conventions

All assembly files use NASM syntax and target x86-64 Linux (ELF64, System V AMD64 ABI).

**Calling convention (System V AMD64):**
- Arguments: `rdi`, `rsi`, `rdx`, `rcx`, `r8`, `r9`
- Return value: `rax`
- Caller-saved: `rax`, `rcx`, `rdx`, `rsi`, `rdi`, `r8`, `r9`, `r10`, `r11`
- Callee-saved: `rbx`, `rbp`, `r12`–`r15`

**CPU dispatch pattern:** Every hot function checks the `cpu_tier` or `cpu_features` bitmask (populated by `_init_cpu_features` in `ws_cpu.asm`) and jumps to the appropriate implementation. Every dispatch chain must end in a scalar fallback that works on baseline SSE2.

Example structure:
```nasm
my_function:
    cmp dword [rel cpu_tier], 3
    jge .avx2_path
    cmp dword [rel cpu_tier], 2
    jge .sse4_path
.sse2_path:
    ; baseline SSE2 implementation
    ret
.sse4_path:
    ; SSE4.2 implementation
    ret
.avx2_path:
    ; AVX2 implementation
    ret
```

## PR Checklist

- [ ] `npm test` passes
- [ ] New assembly paths have a scalar fallback (no code path requires more than SSE2)
- [ ] `binding.gyp` updated if new `.asm` or `.c` files are added to `src/`
- [ ] `CHANGELOG.md` updated under `[Unreleased]`
