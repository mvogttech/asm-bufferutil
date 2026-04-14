# npm Distribution Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package asm-bufferutil for zero-compile npm installs with prebuilt binaries across 4 platforms and 3 Node versions, as a drop-in bufferutil replacement.

**Architecture:** Ship prebuilt `.node` binaries via `prebuildify` + `node-gyp-build`. The V8 direct C++ API binding (`ws_fast_api.cc`) is retained for maximum performance, producing per-ABI prebuilds. `index.js` uses `node-gyp-build` to discover prebuilds at runtime, falling back to a pure JS implementation.

**Tech Stack:** prebuildify, node-gyp-build, node-gyp, NASM (Linux CI only), GitHub Actions

**Spec:** `docs/superpowers/specs/2026-04-13-npm-packaging-design.md`

---

### File Map

| Action | File | Responsibility |
|--------|------|---------------|
| Delete | `src/ws_napi.c` | Unused N-API binding (dead code) |
| Rewrite | `index.js` | node-gyp-build loader + fallback require |
| Create | `fallback.js` | Pure JS `{ mask, unmask }` for non-native environments |
| Modify | `package.json` | Dependencies, scripts, files, os/cpu fields |
| Create | `LICENSE` | MIT license text |
| Modify | `binding.gyp` | Gate x86 cflags behind `target_arch=='x64'` for arm64 compat |
| Create | `.github/workflows/prebuild.yml` | CI: build prebuilds on 4 platforms, upload artifacts |
| Modify | `.npmignore` | Ensure `prebuilds/` is not ignored |
| Modify | `.gitignore` | Ensure `prebuilds/` is not ignored |

---

### Task 1: Delete `ws_napi.c` and commit

**Files:**
- Delete: `src/ws_napi.c`

- [ ] **Step 1: Delete the file**

```bash
rm src/ws_napi.c
```

- [ ] **Step 2: Verify no remaining references**

Search for `ws_napi` in binding.gyp and other source files. It should not be referenced anywhere (it was already excluded from the build — `ws_fast_api.cc` is the active binding).

```bash
grep -r "ws_napi" --include="*.gyp" --include="*.cc" --include="*.c" --include="*.js" --include="*.json" .
```

Expected: No matches (the file was never referenced in binding.gyp or index.js — it was orphaned when ws_fast_api.cc replaced it).

- [ ] **Step 3: Commit**

```bash
git add -u src/ws_napi.c
git commit -m "chore: remove unused ws_napi.c (replaced by ws_fast_api.cc)"
```

---

### Task 2: Create `fallback.js`

**Files:**
- Create: `fallback.js`

- [ ] **Step 1: Create the fallback module**

Create `fallback.js` in the project root with the pure JavaScript mask/unmask implementation:

```javascript
'use strict';

const mask = (source, mask, output, offset, length) => {
  for (let i = 0; i < length; i++) {
    output[offset + i] = source[i] ^ mask[i & 3];
  }
};

const unmask = (buffer, mask) => {
  const length = buffer.length;
  for (let i = 0; i < length; i++) {
    buffer[i] ^= mask[i & 3];
  }
};

module.exports = { mask, unmask };
```

- [ ] **Step 2: Verify the fallback works**

Quick sanity test in Node REPL:

```bash
node -e "
const fb = require('./fallback');
const src = Buffer.from('hello');
const mask = Buffer.from([0xAA, 0xBB, 0xCC, 0xDD]);
const out = Buffer.alloc(src.length);
fb.mask(src, mask, out, 0, src.length);
fb.unmask(out, mask);
console.log(out.toString() === 'hello' ? 'PASS' : 'FAIL');
"
```

Expected: `PASS`

- [ ] **Step 3: Commit**

```bash
git add fallback.js
git commit -m "chore: extract JS fallback into fallback.js"
```

---

### Task 3: Rewrite `index.js`

**Files:**
- Modify: `index.js`

- [ ] **Step 1: Rewrite index.js**

Replace the entire contents of `index.js` with the `node-gyp-build` loader pattern:

```javascript
'use strict';

try {
  module.exports = require('node-gyp-build')(__dirname);
} catch (e) {
  module.exports = require('./fallback');
}
```

- [ ] **Step 2: Verify the fallback path works**

`node-gyp-build` isn't installed yet, so this will fall through to fallback.js. Verify:

```bash
node -e "
const m = require('.');
const src = Buffer.from('test');
const mask = Buffer.from([1,2,3,4]);
const out = Buffer.alloc(4);
m.mask(src, mask, out, 0, 4);
m.unmask(out, mask);
console.log(out.toString() === 'test' ? 'PASS: fallback works' : 'FAIL');
"
```

Expected: `PASS: fallback works`

- [ ] **Step 3: Commit**

```bash
git add index.js
git commit -m "chore: rewrite index.js to use node-gyp-build with fallback"
```

---

### Task 4: Update `package.json`

**Files:**
- Modify: `package.json`

- [ ] **Step 1: Apply all package.json changes**

Make the following edits to `package.json`:

1. In `dependencies`, replace `"node-gyp": "^12.0.0"` with `"node-gyp-build": "^4.8.0"`.

2. In `devDependencies`, add `"node-gyp": "^12.0.0"` and `"prebuildify": "^6.0.0"` (keep existing `bufferutil` and `js-yaml`).

3. In `scripts`:
   - Change `"install"` from `"node-gyp rebuild"` to `"node-gyp-build"`
   - Add `"prebuild": "prebuildify --strip --target=20.0.0 --target=22.0.0 --target=24.0.0"`
   - Keep `"build"`, `"test"`, and `"bench"` unchanged.

4. In `files`, change from `["src/", "index.js", "binding.gyp"]` to `["src/", "index.js", "fallback.js", "binding.gyp", "prebuilds/"]`.

5. In `os`, change from `["linux", "win32"]` to `["linux", "win32", "darwin"]`.

6. In `cpu`, change from `["x64"]` to `["x64", "arm64"]`.

The final `package.json` should look like:

```json
{
  "name": "asm-bufferutil",
  "version": "0.1.0",
  "description": "WebSocket buffer utils with hand-written x86-64 assembly (SSE2 SIMD) — drop-in replacement for bufferutil",
  "main": "index.js",
  "files": [
    "src/",
    "index.js",
    "fallback.js",
    "binding.gyp",
    "prebuilds/"
  ],
  "scripts": {
    "install": "node-gyp-build",
    "build": "node-gyp rebuild",
    "prebuild": "prebuildify --strip --target=20.0.0 --target=22.0.0 --target=24.0.0",
    "test": "node test/index.js",
    "bench": "node --expose-gc bench/index.js"
  },
  "keywords": [
    "websocket",
    "bufferutil",
    "simd",
    "asm",
    "napi",
    "performance",
    "x86-64"
  ],
  "repository": {
    "type": "git",
    "url": "git+https://github.com/mvogttech/asm-bufferutil.git"
  },
  "bugs": {
    "url": "https://github.com/mvogttech/asm-bufferutil/issues"
  },
  "homepage": "https://github.com/mvogttech/asm-bufferutil#readme",
  "dependencies": {
    "node-gyp-build": "^4.8.0"
  },
  "devDependencies": {
    "bufferutil": "^4.1.0",
    "js-yaml": "^4.1.1",
    "node-gyp": "^12.0.0",
    "prebuildify": "^6.0.0"
  },
  "engines": {
    "node": ">=20.0.0"
  },
  "os": [
    "linux",
    "win32",
    "darwin"
  ],
  "cpu": [
    "x64",
    "arm64"
  ],
  "license": "MIT"
}
```

- [ ] **Step 2: Install new dependencies**

```bash
npm install --ignore-scripts
```

Expected: `node-gyp-build` appears in `node_modules/`, `prebuildify` appears in `node_modules/`.

- [ ] **Step 3: Verify `node-gyp-build` install script works**

Now that `node-gyp-build` is installed, the install script should succeed. Since there are no prebuilds yet and there IS a `build/Release/asm_bufferutil.node` from a previous source build, `node-gyp-build` should find it:

```bash
node -e "const b = require('.'); console.log(typeof b.mask === 'function' ? 'PASS: native loaded' : 'PASS: fallback loaded');"
```

Expected: `PASS: native loaded` (if build/Release exists) or `PASS: fallback loaded` (if not).

- [ ] **Step 4: Commit**

```bash
git add package.json
git commit -m "chore: switch to node-gyp-build, add prebuildify, expand platform support"
```

---

### Task 5: Add `LICENSE` file

**Files:**
- Create: `LICENSE`

- [ ] **Step 1: Create MIT license**

Create `LICENSE` in the project root:

```
MIT License

Copyright (c) 2025-present Michael Vogt

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Commit**

```bash
git add LICENSE
git commit -m "chore: add MIT LICENSE file"
```

---

### Task 6: Update `binding.gyp` for macOS/arm64 compatibility

**Files:**
- Modify: `binding.gyp`

- [ ] **Step 1: Gate x86 cflags behind target_arch check**

The current `binding.gyp` has a top-level `cflags` array with x86-specific flags that will cause compilation errors on arm64 (Apple Silicon):

```json
"cflags": ["-Wall", "-O2", "-mssse3", "-msse4.1", "-msha", "-mgfni"]
```

Replace the top-level `cflags` with architecture-conditional flags. The new `binding.gyp` should be:

```json
{
  "targets": [
    {
      "target_name": "asm_bufferutil",
      "sources": [
        "src/ws_fast_api.cc",
        "src/ws_sha1_ni.c"
      ],
      "conditions": [
        ["OS!='linux' or target_arch!='x64'", {
          "sources": ["src/ws_fallback.c"]
        }],
        ["OS=='win'", {
          "msvs_settings": {
            "VCCLCompilerTool": {
              "AdditionalOptions": ["/arch:AVX2"]
            }
          }
        }],
        ["OS!='win' and target_arch=='x64'", {
          "cflags": ["-Wall", "-O2", "-mssse3", "-msse4.1", "-msha", "-mgfni"],
          "xcode_settings": {
            "OTHER_CFLAGS": ["-Wall", "-O2", "-mssse3", "-msse4.1", "-msha", "-mgfni"]
          }
        }],
        ["OS!='win' and target_arch!='x64'", {
          "cflags": ["-Wall", "-O2"],
          "xcode_settings": {
            "OTHER_CFLAGS": ["-Wall", "-O2"]
          }
        }],
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
            },
            {
              "action_name": "assemble_utf8",
              "inputs":  ["src/ws_utf8_asm.asm"],
              "outputs": ["<(INTERMEDIATE_DIR)/ws_utf8_asm.o"],
              "action": ["nasm", "-f", "elf64",
                         "-o", "<(INTERMEDIATE_DIR)/ws_utf8_asm.o",
                         "src/ws_utf8_asm.asm"]
            }
          ],
          "link_settings": {
            "libraries": [
              "<(INTERMEDIATE_DIR)/ws_cpu.o",
              "<(INTERMEDIATE_DIR)/ws_mask_asm.o",
              "<(INTERMEDIATE_DIR)/ws_base64_asm.o",
              "<(INTERMEDIATE_DIR)/ws_crc32_asm.o",
              "<(INTERMEDIATE_DIR)/ws_utf8_asm.o"
            ]
          }
        }]
      ],
      "defines": ["NAPI_VERSION=9"]
    }
  ]
}
```

Key changes from the original:
- Removed top-level `cflags` (was unconditional, broke arm64)
- Added `OS!='win' and target_arch=='x64'` condition for x86 SIMD cflags
- Added `OS!='win' and target_arch!='x64'` condition for arm64 with basic flags only
- Added `xcode_settings.OTHER_CFLAGS` for macOS (Xcode ignores `cflags`, uses its own key)
- All existing Linux/NASM/Windows conditions unchanged

- [ ] **Step 2: Verify the build still works on current platform (Windows)**

```bash
npm run build
```

Expected: Build succeeds (uses MSVC AVX2 path, unaffected by cflags changes since those are behind `OS!='win'`).

- [ ] **Step 3: Run tests**

```bash
npm test
```

Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add binding.gyp
git commit -m "fix: gate x86 cflags behind target_arch for macOS arm64 compatibility"
```

---

### Task 7: Update `.npmignore` and `.gitignore`

**Files:**
- Modify: `.npmignore`
- Modify: `.gitignore`

- [ ] **Step 1: Verify `.npmignore` does NOT exclude prebuilds**

Current `.npmignore` content:
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

`prebuilds/` is not listed — good. No change needed to `.npmignore`.

- [ ] **Step 2: Add `prebuilds/` exception to `.gitignore`**

The current `.gitignore` has `*.node` which would exclude prebuilt binaries. We need an exception for prebuilds. Also, `prebuilds/` should not be git-ignored since we want to check them in (or at least not block them).

Add these lines to `.gitignore`:

```
# Allow prebuilt binaries in prebuilds/ directory
!prebuilds/
!prebuilds/**/*.node
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore: allow prebuilt .node files in prebuilds/ directory"
```

---

### Task 8: Create `.github/workflows/prebuild.yml`

**Files:**
- Create: `.github/workflows/prebuild.yml`

- [ ] **Step 1: Create the prebuild workflow**

Create `.github/workflows/prebuild.yml`:

```yaml
name: Prebuild

on:
  # Manual trigger for building prebuilds on demand
  workflow_dispatch:
  # Automatically build on version tags
  push:
    tags:
      - 'v*'

jobs:
  prebuild:
    name: Prebuild ${{ matrix.os }}
    runs-on: ${{ matrix.os }}

    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, windows-latest, macos-latest, macos-13]
        # ubuntu-latest  = linux-x64
        # windows-latest = win32-x64
        # macos-latest   = darwin-arm64 (Apple Silicon)
        # macos-13       = darwin-x64 (Intel Mac)

    steps:
      - uses: actions/checkout@v4

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 22

      - name: Install NASM
        if: runner.os == 'Linux'
        run: sudo apt-get install -y nasm

      - name: Install dependencies
        run: npm install --ignore-scripts

      - name: Build prebuilds
        run: npx prebuildify --strip --target=20.0.0 --target=22.0.0 --target=24.0.0

      - name: Upload prebuilds
        uses: actions/upload-artifact@v4
        with:
          name: prebuilds-${{ matrix.os }}
          path: prebuilds/

  # Collect all prebuilds into a single artifact
  collect:
    name: Collect prebuilds
    needs: prebuild
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Download all prebuilds
        uses: actions/download-artifact@v4
        with:
          path: prebuilds-all/
          pattern: prebuilds-*

      - name: Merge prebuilds into prebuilds/
        run: |
          mkdir -p prebuilds
          for dir in prebuilds-all/prebuilds-*/; do
            cp -r "$dir"/* prebuilds/ 2>/dev/null || true
          done

      - name: List prebuilds
        run: find prebuilds -type f | sort

      - name: Upload merged prebuilds
        uses: actions/upload-artifact@v4
        with:
          name: prebuilds-all-platforms
          path: prebuilds/
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/prebuild.yml
git commit -m "ci: add prebuild workflow for cross-platform prebuilt binaries"
```

---

### Task 9: Verify everything end-to-end

- [ ] **Step 1: Rebuild from source and run tests**

```bash
npm run build && npm test
```

Expected: Build succeeds, all tests pass.

- [ ] **Step 2: Verify fallback path**

Temporarily rename the build directory and confirm the fallback JS kicks in:

```bash
mv build build.bak
node -e "const m = require('.'); console.log(typeof m.mask); console.log(typeof m.unmask);"
mv build.bak build
```

Expected output:
```
function
function
```

- [ ] **Step 3: Dry-run npm pack to inspect tarball contents**

```bash
npm pack --dry-run
```

Expected: The tarball includes `index.js`, `fallback.js`, `binding.gyp`, `src/`, `LICENSE`, `package.json`, and `prebuilds/` (if present). It does NOT include `test/`, `bench/`, `.github/`, `.claude/`, `docs/`, `CONTRIBUTING.md`.

- [ ] **Step 4: Commit any fixes**

If any issues were found, fix and commit. Otherwise, no action needed.

- [ ] **Step 5: Final commit with version note**

```bash
git add -A
git commit -m "chore: npm packaging ready — prebuildify + node-gyp-build distribution"
```
