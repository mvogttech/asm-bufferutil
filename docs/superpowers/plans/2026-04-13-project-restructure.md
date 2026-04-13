# Project Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize `asm-bufferutil` from a root-level file dump into a professional open-source npm package with `src/`, `test/`, `bench/` directories, CI, contributor scaffolding, and complete npm registry metadata.

**Architecture:** All native sources (`.asm`, `.c`) move to `src/`; test and bench files move to their own directories; `binding.gyp` and root-level JS stay at root (required by node-gyp/npm). No assembly logic changes — this is purely structural.

**Tech Stack:** NASM, node-gyp, Node.js N-API, GitHub Actions

---

## File Map

### Moved
| From | To |
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

### Modified
| File | What changes |
|---|---|
| `binding.gyp` | All source paths prefixed with `src/` |
| `package.json` | `"test"` and `"bench"` script paths + metadata fields added |
| `README.md` | File structure section + badges + build prerequisites |
| `.gitignore` | Add `build/`, `*.o`, `*.node`; remove `docs/`, `dist/` |

### Created
| File | Purpose |
|---|---|
| `.npmignore` | Exclude dev files from published package |
| `CHANGELOG.md` | Keep-a-changelog format, v0.1.0 entry |
| `CONTRIBUTING.md` | Build prerequisites, workflow, ASM conventions, PR checklist |
| `.github/workflows/ci.yml` | Multi-platform CI matrix |

### Stays at Root (unchanged)
`index.js`, `binding.gyp` (modified but stays at root), `package.json` (modified), `README.md` (modified)

---

## Task 1: Move source files into `src/`

**Files:**
- Move: `ws_napi.c` → `src/ws_napi.c`
- Move: `ws_sha1_ni.c` → `src/ws_sha1_ni.c`
- Move: `ws_mask_asm.asm` → `src/ws_mask_asm.asm`
- Move: `ws_base64_asm.asm` → `src/ws_base64_asm.asm`
- Move: `ws_cpu.asm` → `src/ws_cpu.asm`
- Move: `ws_crc32_asm.asm` → `src/ws_crc32_asm.asm`
- Move: `websocket_server.asm` → `src/websocket_server.asm`

- [ ] **Step 1: Create `src/` and move all native source files**

```bash
mkdir src
git mv ws_napi.c src/ws_napi.c
git mv ws_sha1_ni.c src/ws_sha1_ni.c
git mv ws_mask_asm.asm src/ws_mask_asm.asm
git mv ws_base64_asm.asm src/ws_base64_asm.asm
git mv ws_cpu.asm src/ws_cpu.asm
git mv ws_crc32_asm.asm src/ws_crc32_asm.asm
git mv websocket_server.asm src/websocket_server.asm
```

- [ ] **Step 2: Verify git sees renames, not deletes**

```bash
git status
```

Expected: each file shows as `renamed: ws_napi.c -> src/ws_napi.c` (and similarly for others). No `deleted:` entries.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor: move all native sources into src/"
```

---

## Task 2: Update `binding.gyp` source paths

**Files:**
- Modify: `binding.gyp`

- [ ] **Step 1: Update C source paths**

In `binding.gyp`, change:
```json
"sources": [
  "ws_napi.c",
  "ws_sha1_ni.c"
]
```
to:
```json
"sources": [
  "src/ws_napi.c",
  "src/ws_sha1_ni.c"
]
```

- [ ] **Step 2: Update all four NASM action input paths**

For each of the four `actions` entries, change the source `.asm` path (the last positional argument to `nasm`). The `<(INTERMEDIATE_DIR)` output paths stay unchanged.

Change:
```json
"action": ["nasm", "-f", "elf64", "-o", "<(INTERMEDIATE_DIR)/ws_cpu.o", "ws_cpu.asm"]
```
to:
```json
"action": ["nasm", "-f", "elf64", "-o", "<(INTERMEDIATE_DIR)/ws_cpu.o", "src/ws_cpu.asm"]
```

Do the same for the other three actions:
- `"ws_mask_asm.asm"` → `"src/ws_mask_asm.asm"`
- `"ws_base64_asm.asm"` → `"src/ws_base64_asm.asm"`
- `"ws_crc32_asm.asm"` → `"src/ws_crc32_asm.asm"`

Also update the `"inputs"` arrays to match:
```json
"inputs": ["src/ws_cpu.asm"]
"inputs": ["src/ws_mask_asm.asm"]
"inputs": ["src/ws_base64_asm.asm"]
"inputs": ["src/ws_crc32_asm.asm"]
```

- [ ] **Step 3: Verify the full updated `binding.gyp` looks correct**

The complete file should be:
```json
{
  "targets": [
    {
      "target_name": "asm_bufferutil",
      "sources": [
        "src/ws_napi.c",
        "src/ws_sha1_ni.c"
      ],
      "conditions": [
        ["OS=='linux' and target_arch=='x64'", {
          "actions": [
            {
              "action_name": "assemble_cpu",
              "inputs":  ["src/ws_cpu.asm"],
              "outputs": ["<(INTERMEDIATE_DIR)/ws_cpu.o"],
              "action": ["nasm", "-f", "elf64",
                         "-o", "<(INTERMEDIATE_DIR)/ws_cpu.o",
                         "src/ws_cpu.asm"]
            },
            {
              "action_name": "assemble_mask",
              "inputs":  ["src/ws_mask_asm.asm"],
              "outputs": ["<(INTERMEDIATE_DIR)/ws_mask_asm.o"],
              "action": ["nasm", "-f", "elf64",
                         "-o", "<(INTERMEDIATE_DIR)/ws_mask_asm.o",
                         "src/ws_mask_asm.asm"]
            },
            {
              "action_name": "assemble_base64",
              "inputs":  ["src/ws_base64_asm.asm"],
              "outputs": ["<(INTERMEDIATE_DIR)/ws_base64_asm.o"],
              "action": ["nasm", "-f", "elf64",
                         "-o", "<(INTERMEDIATE_DIR)/ws_base64_asm.o",
                         "src/ws_base64_asm.asm"]
            },
            {
              "action_name": "assemble_crc32",
              "inputs":  ["src/ws_crc32_asm.asm"],
              "outputs": ["<(INTERMEDIATE_DIR)/ws_crc32_asm.o"],
              "action": ["nasm", "-f", "elf64",
                         "-o", "<(INTERMEDIATE_DIR)/ws_crc32_asm.o",
                         "src/ws_crc32_asm.asm"]
            }
          ],
          "link_settings": {
            "libraries": [
              "<(INTERMEDIATE_DIR)/ws_cpu.o",
              "<(INTERMEDIATE_DIR)/ws_mask_asm.o",
              "<(INTERMEDIATE_DIR)/ws_base64_asm.o",
              "<(INTERMEDIATE_DIR)/ws_crc32_asm.o"
            ]
          }
        }]
      ],
      "cflags": ["-Wall", "-O2", "-msha", "-mgfni"],
      "defines": ["NAPI_VERSION=8"]
    }
  ]
}
```

- [ ] **Step 4: Verify JS fallback still works (cross-platform build check)**

```bash
node test.js
```

Expected: tests pass (using JS fallback on non-Linux, or native on Linux). If `test.js` is not found, the test move in Task 3 hasn't happened yet — run `node -e "require('./index'); console.log('index.js loads OK')"` instead.

- [ ] **Step 5: Commit**

```bash
git add binding.gyp
git commit -m "build: update binding.gyp source paths for src/ layout"
```

---

## Task 3: Move test files into `test/` and update script

**Files:**
- Move: `test.js` → `test/index.js`
- Move: `test_crc32.c` → `test/crc32.c`
- Move: `test_client.html` → `test/client.html`
- Modify: `package.json` (`"test"` script)

- [ ] **Step 1: Move test files**

```bash
mkdir test
git mv test.js test/index.js
git mv test_crc32.c test/crc32.c
git mv test_client.html test/client.html
```

- [ ] **Step 2: Update `package.json` test script**

Change:
```json
"test": "node test.js"
```
to:
```json
"test": "node test/index.js"
```

- [ ] **Step 3: Verify tests still pass**

```bash
npm test
```

Expected: same output as before the move. All tests pass.

- [ ] **Step 4: Commit**

```bash
git add test/ package.json
git commit -m "refactor: move test files into test/"
```

---

## Task 4: Move bench into `bench/` and update script

**Files:**
- Move: `bench.js` → `bench/index.js`
- Modify: `package.json` (`"bench"` script)

- [ ] **Step 1: Move bench file**

```bash
mkdir bench
git mv bench.js bench/index.js
```

- [ ] **Step 2: Update `package.json` bench script**

Change:
```json
"bench": "node bench.js"
```
to:
```json
"bench": "node bench/index.js"
```

- [ ] **Step 3: Verify bench runs**

```bash
npm run bench
```

Expected: benchmark output printed without errors.

- [ ] **Step 4: Commit**

```bash
git add bench/ package.json
git commit -m "refactor: move bench into bench/"
```

---

## Task 5: Update `.gitignore`

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Replace `.gitignore` content**

Replace the entire file with:
```
build/
node_modules/
package-lock.json
*.o
*.node
.claude/
```

> Note: `docs/` and `dist/` are removed (docs is tracked; dist doesn't exist). `.claude/` is kept as it was already there.

- [ ] **Step 2: Verify `build/` and `package-lock.json` are now ignored**

```bash
git status
```

Expected: `build/` and `package-lock.json` no longer appear in untracked files.

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore: update .gitignore — track docs, ignore build artifacts"
```

---

## Task 6: Create `.npmignore`

**Files:**
- Create: `.npmignore`

- [ ] **Step 1: Create `.npmignore`**

```
.github/
.claude/
test/
bench/
docs/
CONTRIBUTING.md
CHANGELOG.md
.gitignore
```

- [ ] **Step 2: Verify what `npm pack` would include**

```bash
npm pack --dry-run
```

Expected output lists only: `index.js`, `binding.gyp`, `src/` files, `package.json`, `README.md`. The `test/`, `bench/`, `.github/`, `docs/` directories should NOT appear.

- [ ] **Step 3: Commit**

```bash
git add .npmignore
git commit -m "chore: add .npmignore to control published package contents"
```

---

## Task 7: Update `package.json` metadata

**Files:**
- Modify: `package.json`

- [ ] **Step 1: Add registry metadata fields**

The final `package.json` should be:
```json
{
  "name": "asm-bufferutil",
  "version": "0.1.0",
  "description": "WebSocket buffer utils with hand-written x86-64 assembly (SSE2 SIMD) — drop-in replacement for bufferutil",
  "main": "index.js",
  "files": ["src/", "index.js", "binding.gyp"],
  "scripts": {
    "install": "node-gyp rebuild",
    "build": "node-gyp rebuild",
    "test": "node test/index.js",
    "bench": "node bench/index.js"
  },
  "keywords": ["websocket", "bufferutil", "simd", "asm", "napi", "performance", "x86-64"],
  "repository": {
    "type": "git",
    "url": "git+https://github.com/mvogttech/asm-bufferutil.git"
  },
  "bugs": {
    "url": "https://github.com/mvogttech/asm-bufferutil/issues"
  },
  "homepage": "https://github.com/mvogttech/asm-bufferutil#readme",
  "dependencies": {
    "node-gyp": "^10.0.0"
  },
  "engines": {
    "node": ">=16.0.0"
  },
  "os": ["linux", "win32"],
  "cpu": ["x64"],
  "license": "MIT"
}
```

- [ ] **Step 2: Verify JSON is valid**

```bash
node -e "require('./package.json'); console.log('valid JSON')"
```

Expected: `valid JSON`

- [ ] **Step 3: Commit**

```bash
git add package.json
git commit -m "chore: add npm registry metadata (keywords, repository, bugs, homepage, files)"
```

---

## Task 8: Create `CHANGELOG.md`

**Files:**
- Create: `CHANGELOG.md`

- [ ] **Step 1: Create `CHANGELOG.md`**

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

## [0.1.0] - 2026-04-13

### Added
- `mask(source, mask, output, offset, length)` — WebSocket frame masking with SSE2/NT-store SIMD dispatch
- `unmask(buffer, mask)` — In-place WebSocket frame unmasking with SSE2/NT-store SIMD dispatch
- `base64Encode(input)` — Base64 encoding with AVX2/GFNI/SSE2/scalar CPU dispatch
- `crc32(buffer, init)` — CRC32 using SSE4.2 `CRC32` instruction
- `sha1(data)` — SHA-1 using Intel SHA-NI hardware instructions
- `cpuFeatures` — Bitmask exposing detected CPU capabilities (SSE2, AVX2, BMI2, GFNI, SHA-NI, SSE4.2)
- BMI2 runtime dispatch for WebSocket frame parsing (PEXT/LZCNT/RORX)
- N-API ABI-stable interface — works across Node.js versions without recompile
- Pure JavaScript fallback for non-Linux or non-x64 platforms
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: add CHANGELOG.md with initial 0.1.0 entry"
```

---

## Task 9: Create `CONTRIBUTING.md`

**Files:**
- Create: `CONTRIBUTING.md`

- [ ] **Step 1: Create `CONTRIBUTING.md`**

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add CONTRIBUTING.md
git commit -m "docs: add CONTRIBUTING.md with build prerequisites and ASM conventions"
```

---

## Task 10: Create `.github/workflows/ci.yml`

**Files:**
- Create: `.github/workflows/ci.yml`

**Note on non-Linux builds:** `ws_napi.c` declares `extern` symbols for assembly functions. On Windows and macOS, these symbols are not linked (no NASM step runs). The linker will fail. The `npm install --ignore-scripts` + separate `npm run build` pattern below lets `npm test` run regardless, falling back to the JS path.

- [ ] **Step 1: Create workflow directory and file**

```bash
mkdir -p .github/workflows
```

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    name: Node ${{ matrix.node }} on ${{ matrix.os }}
    runs-on: ${{ matrix.os }}

    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, windows-latest, macos-latest]
        node: [18, 20, 22]

    steps:
      - uses: actions/checkout@v4

      - name: Set up Node.js ${{ matrix.node }}
        uses: actions/setup-node@v4
        with:
          node-version: ${{ matrix.node }}

      - name: Install NASM
        if: runner.os == 'Linux'
        run: sudo apt-get install -y nasm

      - name: Install dependencies (skip native build)
        run: npm install --ignore-scripts

      - name: Build native addon
        run: npm run build
        continue-on-error: ${{ runner.os != 'Linux' }}

      - name: Run tests
        run: npm test
```

- [ ] **Step 2: Verify YAML syntax**

```bash
node -e "
const fs = require('fs');
const content = fs.readFileSync('.github/workflows/ci.yml', 'utf8');
// Basic structure check
if (!content.includes('on:') || !content.includes('jobs:')) {
  console.error('YAML missing required sections');
  process.exit(1);
}
console.log('YAML structure looks OK — validate fully at https://yaml.lint.com if needed');
"
```

- [ ] **Step 3: Commit**

```bash
git add .github/
git commit -m "ci: add GitHub Actions workflow — Linux native + Windows/macOS JS fallback"
```

---

## Task 11: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add CI, npm, and license badges below the `# asm-bufferutil` title**

Insert after line 1 (`# asm-bufferutil`), before the bold description line:

```markdown
[![CI](https://github.com/mvogttech/asm-bufferutil/actions/workflows/ci.yml/badge.svg)](https://github.com/mvogttech/asm-bufferutil/actions/workflows/ci.yml)
[![npm version](https://img.shields.io/npm/v/asm-bufferutil.svg)](https://www.npmjs.com/package/asm-bufferutil)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
```

- [ ] **Step 2: Replace the `## File structure` section**

Replace the existing file structure block (lines 151–164 in the original README) with:

```markdown
## File structure

```
asm-bufferutil/
├── src/
│   ├── ws_napi.c               # N-API C glue layer
│   ├── ws_sha1_ni.c            # SHA-1 with Intel SHA-NI intrinsics
│   ├── ws_mask_asm.asm         # XOR masking (SSE2/NT-store dispatch)
│   ├── ws_base64_asm.asm       # Base64 (AVX2/GFNI/SSE2/scalar dispatch)
│   ├── ws_cpu.asm              # CPU feature detection + tier bitmask
│   ├── ws_crc32_asm.asm        # CRC32 (SSE4.2)
│   └── websocket_server.asm    # WebSocket server-side frame assembly
├── test/
│   ├── index.js                # Correctness test suite
│   ├── crc32.c                 # C-level CRC32 harness
│   └── client.html             # Browser WebSocket test client
├── bench/
│   └── index.js                # Throughput benchmarks
├── .github/workflows/ci.yml
├── binding.gyp                 # node-gyp build config
├── index.js                    # JS entry point with native/fallback dispatch
├── package.json
├── CHANGELOG.md
├── CONTRIBUTING.md
└── README.md
```
```

- [ ] **Step 3: Update the Build prerequisites section**

Find the `## Build` section and replace its content with:

```markdown
## Build

Prerequisites: `nasm`, `node-gyp`, Node.js ≥ 16, **Linux x86-64** for native SIMD paths.

On Windows and macOS, `npm install` will compile the C layer only. The assembly SIMD paths are Linux x86-64 exclusive. The pure JavaScript fallback is used automatically on other platforms.

```bash
# Install NASM (Ubuntu/Debian)
sudo apt install nasm

# Build the native addon
npm install
npm run build

# Run tests
npm test

# Run benchmarks
npm run bench
```
```

- [ ] **Step 4: Run tests one final time to confirm nothing broke**

```bash
npm test
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: update README — correct file structure, add CI/npm/license badges, platform notes"
```

---

## Final Verification

- [ ] **Confirm root is clean**

```bash
ls *.asm *.c 2>/dev/null && echo "ERROR: stray source files in root" || echo "root is clean"
```

Expected: `root is clean`

- [ ] **Confirm directory structure**

```bash
ls src/ test/ bench/ .github/workflows/
```

Expected: all four directories exist with the correct files.

- [ ] **Confirm npm test passes**

```bash
npm test
```

Expected: all tests pass.
