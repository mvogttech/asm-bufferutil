# Project Restructure Design — asm-bufferutil

**Date:** 2026-04-13
**Scope:** Full professional restructure for open-source npm publication
**Repo:** https://github.com/mvogttech/asm-bufferutil

---

## Context

`asm-bufferutil` is a drop-in replacement for the `bufferutil` npm package, implementing WebSocket frame masking/unmasking in hand-written x86-64 NASM assembly with SSE2/AVX2/BMI2/SHA-NI SIMD dispatch. It exposes a Node.js N-API addon.

The project has grown organically — all `.asm` and `.c` source files are currently loose in the root directory, tests and benchmarks are unseparated, the `.gitignore` is incomplete, and several npm registry metadata fields are missing. The README describes a `src/` layout that was never implemented.

This document defines the restructure to bring the project to professional open-source npm package standards.

---

## Goals

1. Source files organized under `src/` — matches README description, matches ecosystem norm for native Node addons
2. Tests under `test/`, benchmarks under `bench/`
3. `.gitignore` covers all build artifacts
4. `.npmignore` + `package.json` `"files"` field control what gets published
5. GitHub Actions CI runs on Linux (native build), Windows, and macOS (C-only build + JS fallback)
6. `CHANGELOG.md` and `CONTRIBUTING.md` added
7. `package.json` metadata complete for npm registry
8. README updated: correct file structure, CI/npm/license badges

---

## Section 1: Directory Structure

### File Moves

| From (root) | To |
|---|---|
| `ws_napi.c` | `src/ws_napi.c` |
| `ws_sha1_ni.c` | `src/ws_sha1_ni.c` |
| `ws_mask_asm.asm` | `src/ws_mask_asm.asm` |
| `ws_base64_asm.asm` | `src/ws_base64_asm.asm` |
| `ws_cpu.asm` | `src/ws_cpu.asm` |
| `ws_crc32_asm.asm` | `src/ws_crc32_asm.asm` |
| `websocket_server.asm` | `src/websocket_server.asm` |
| `test.js` | `test/index.js` |
| `test_crc32.c` | `test/crc32.c` |
| `test_client.html` | `test/client.html` |
| `bench.js` | `bench/index.js` |

### Files Staying at Root

`index.js`, `binding.gyp`, `package.json`, `README.md` — required at root by node-gyp and npm.

### New Files

| Path | Purpose |
|---|---|
| `.gitignore` | Updated to cover `build/`, `node_modules/`, `*.node`, `*.o`, `package-lock.json` |
| `.npmignore` | Excludes `.github/`, `test/`, `bench/`, `docs/`, non-README markdown |
| `CHANGELOG.md` | Keep-a-changelog format, starts with `[Unreleased]` + `[0.1.0]` |
| `CONTRIBUTING.md` | Build prerequisites, dev workflow, assembly conventions, PR checklist |
| `.github/workflows/ci.yml` | Multi-platform CI matrix |

### Final Layout

```
asm-bufferutil/
├── src/
│   ├── ws_napi.c               # N-API C glue layer
│   ├── ws_sha1_ni.c            # SHA-1 with Intel SHA-NI intrinsics
│   ├── ws_mask_asm.asm         # XOR masking (SSE2/NT-store dispatch)
│   ├── ws_base64_asm.asm       # Base64 (AVX2/GFNI/SSE2/scalar dispatch)
│   ├── ws_cpu.asm              # CPU feature detection + tier bitmask
│   ├── ws_crc32_asm.asm        # CRC32 (SSE4.2)
│   └── websocket_server.asm    # WebSocket server assembly (purpose TBD — add inline comment during implementation)
├── test/
│   ├── index.js                # Correctness test suite
│   ├── crc32.c                 # C-level CRC32 harness
│   └── client.html             # Browser WebSocket test client
├── bench/
│   └── index.js                # Throughput benchmarks
├── .github/
│   └── workflows/
│       └── ci.yml
├── binding.gyp
├── index.js                    # JS entry point with native/fallback dispatch
├── package.json
├── CHANGELOG.md
├── CONTRIBUTING.md
├── .gitignore
├── .npmignore
└── README.md
```

---

## Section 2: `binding.gyp` Path Updates

All source paths updated to reference `src/`:

```json
"sources": ["src/ws_napi.c", "src/ws_sha1_ni.c"]
```

NASM action inputs updated:
```
src/ws_cpu.asm       → <INTERMEDIATE_DIR>/ws_cpu.o
src/ws_mask_asm.asm  → <INTERMEDIATE_DIR>/ws_mask_asm.o
src/ws_base64_asm.asm→ <INTERMEDIATE_DIR>/ws_base64_asm.o
src/ws_crc32_asm.asm → <INTERMEDIATE_DIR>/ws_crc32_asm.o
```

`package.json` scripts updated:
```json
"test": "node test/index.js",
"bench": "node bench/index.js"
```

---

## Section 3: GitHub Actions CI

**File:** `.github/workflows/ci.yml`
**Triggers:** push and pull_request to `main`

### Matrix

| Runner | Node versions | What is tested |
|---|---|---|
| `ubuntu-latest` (x64) | 18, 20, 22 | Full native build (NASM + node-gyp) + test suite |
| `windows-latest` (x64) | 18, 20, 22 | C-only build (no NASM) + test suite |
| `macos-latest` | 18, 20, 22 | C-only build (no NASM) + test suite |

### Non-Linux behavior

`binding.gyp` conditions assembly steps on `OS=='linux' and target_arch=='x64'`. On Windows and macOS, `node-gyp rebuild` succeeds but produces a C-only `.node`. `index.js` loads it without error. The test suite runs against the loaded binding (no JS fallback exercised — the C shim loads fine).

### Linux steps

```yaml
- run: sudo apt-get install -y nasm
- run: npm ci
- run: npm test
```

### Windows/macOS steps

```yaml
- run: npm ci
- run: npm test
```

---

## Section 4: Contributor Scaffolding

### `.gitignore`

```
build/
node_modules/
package-lock.json
*.o
*.node
```

### `.npmignore`

```
.github/
test/
bench/
docs/
CONTRIBUTING.md
CHANGELOG.md
.gitignore
```

### `CHANGELOG.md`

Keep-a-changelog format (`https://keepachangelog.com`). Initial entries:

- `[Unreleased]` — empty section for next release
- `[0.1.0]` — initial feature set: mask/unmask (SSE2/NT-store), base64 (AVX2/GFNI/SSE2/scalar), CRC32 (SSE4.2), SHA-1 (SHA-NI), cpuFeatures bitmask, BMI2 frame parsing

### `CONTRIBUTING.md`

Sections:
1. **Prerequisites** — NASM, node-gyp, Node ≥ 16, Linux x86-64 required for native development
2. **Build & test** — `npm ci && npm test`
3. **Assembly conventions** — NASM syntax, System V AMD64 calling convention, CPU dispatch pattern (cpu_tier check → fast path → scalar fallback)
4. **PR checklist** — tests pass, new ASM paths have scalar fallback, `binding.gyp` updated if new files added

---

## Section 5: `package.json` Metadata

### Add

```json
"keywords": ["websocket", "bufferutil", "simd", "asm", "napi", "performance", "x86-64"],
"repository": {
  "type": "git",
  "url": "git+https://github.com/mvogttech/asm-bufferutil.git"
},
"bugs": {
  "url": "https://github.com/mvogttech/asm-bufferutil/issues"
},
"homepage": "https://github.com/mvogttech/asm-bufferutil#readme",
"files": ["src/", "index.js", "binding.gyp"]
```

The `"files"` field is the authoritative include-list for `npm publish`, working alongside `.npmignore`.

---

## Section 6: README Updates

### Badges (below title)

```markdown
[![CI](https://github.com/mvogttech/asm-bufferutil/actions/workflows/ci.yml/badge.svg)](https://github.com/mvogttech/asm-bufferutil/actions/workflows/ci.yml)
[![npm version](https://img.shields.io/npm/v/asm-bufferutil.svg)](https://www.npmjs.com/package/asm-bufferutil)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
```

### File Structure Section

Replace current (inaccurate) file structure block with the final layout from Section 1.

### Build Prerequisites

Add notes for:
- Windows: Visual Studio Build Tools required for node-gyp; SIMD path only activates on Linux x86-64
- macOS: Xcode CLT required for node-gyp; JS fallback used on non-Linux
- All platforms: Node ≥ 16

---

## Out of Scope

- Changing any assembly logic or adding new SIMD paths
- Publishing to npm (separate step after restructure)
- Adding TypeScript types or JSDoc (separate concern)
- Splitting into multiple packages
