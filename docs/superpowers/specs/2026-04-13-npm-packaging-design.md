# npm Distribution Packaging for asm-bufferutil

**Date:** 2026-04-13
**Status:** Approved
**Goal:** Package asm-bufferutil for npm distribution as a drop-in replacement for bufferutil, with prebuilt binaries for zero-compile installs.

## Context

asm-bufferutil is a high-performance WebSocket buffer utility library using hand-written x86-64 assembly (AVX-512/AVX2/SSE2) with C fallbacks. It exposes the same `mask()` and `unmask()` API as the `bufferutil` npm package used by the `ws` WebSocket library.

Currently the package requires compiling from source on every `npm install`, which demands a C++ toolchain and NASM (Linux). This blocks adoption. bufferutil solves this by shipping prebuilt `.node` binaries via `prebuildify` + `node-gyp-build`.

## Decisions

- **Binding layer:** V8 direct C++ API (`ws_fast_api.cc`), not N-API. Maximizes performance at the cost of per-ABI prebuilds.
- **Platforms:** linux-x64, win32-x64, darwin-x64, darwin-arm64 (4 targets).
- **Node versions:** 20, 22, 24 (3 ABI versions per platform = 12 prebuilds total).
- **N-API file:** Remove `ws_napi.c` (dead code, out of sync with V8 API binding).
- **utf-8-validate:** Deferred to future work.

## Package Structure (after changes)

```
asm-bufferutil/
  index.js              # node-gyp-build loader + require('./fallback') on failure
  fallback.js           # pure JS { mask, unmask } (extracted from index.js)
  binding.gyp           # unchanged (for source builds when no prebuild matches)
  package.json          # updated dependencies, scripts, os/cpu fields
  LICENSE               # MIT license text
  src/
    ws_fast_api.cc      # V8 C++ API binding (unchanged)
    ws_fallback.c       # C/SIMD fallback for non-Linux (unchanged)
    ws_sha1_ni.c        # SHA-1 via SHA-NI (unchanged)
    ws_cpu.asm          # CPU detection (unchanged)
    ws_mask_asm.asm     # Masking assembly (unchanged)
    ws_base64_asm.asm   # Base64 assembly (unchanged)
    ws_crc32_asm.asm    # CRC-32C assembly (unchanged)
    ws_utf8_asm.asm     # UTF-8 validation assembly (unchanged)
  prebuilds/
    linux-x64/
      node.abi{N}.node  # one per Node ABI version (prebuildify names these automatically)
    win32-x64/
      node.abi{N}.node
    darwin-x64/
      node.abi{N}.node
    darwin-arm64/
      node.abi{N}.node
```

## Changes

### 1. Delete `src/ws_napi.c`

Remove the unused N-API binding file. It's out of sync with `ws_fast_api.cc` (missing batch operations, utf8Validate) and will not be maintained.

### 2. Rewrite `index.js`

Replace the hardcoded `require('./build/Release/asm_bufferutil.node')` with `node-gyp-build` discovery:

```javascript
'use strict';

try {
  module.exports = require('node-gyp-build')(__dirname);
} catch (e) {
  module.exports = require('./fallback');
}
```

This matches bufferutil's pattern exactly. `node-gyp-build` searches `prebuilds/` first (by platform, arch, ABI), then falls back to `build/Release/`.

### 3. Create `fallback.js`

Extract the pure JavaScript fallback into its own file:

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

### 4. Update `package.json`

Changes:
- `dependencies`: Replace `"node-gyp": "^12.0.0"` with `"node-gyp-build": "^4.8.0"`
- `devDependencies`: Add `"prebuildify": "^6.0.0"`, add `"node-gyp": "^12.0.0"`
- `scripts.install`: Change from `"node-gyp rebuild"` to `"node-gyp-build"`
- `scripts.prebuild`: Add `"prebuildify --strip --target=20.0.0 --target=22.0.0 --target=24.0.0"`
- `files`: Add `"fallback.js"`, `"prebuilds/"`
- `os`: Add `"darwin"`
- `cpu`: Add `"arm64"`

### 5. Add `LICENSE` file

MIT license with copyright holder: Michael Vogt.

### 6. Update `binding.gyp`

Add macOS conditions so `ws_fallback.c` compiles on darwin. The existing condition `OS!='linux' or target_arch!='x64'` already includes macOS, so the C fallback is already wired up. Verify the cflags work with Apple Clang (they should — `-mssse3`, `-msse4.1` are supported on x86-64 macOS; on arm64 they're ignored/errored, so we need to gate them on `target_arch=='x64'`).

Specific changes:
- Gate x86 cflags (`-mssse3`, `-msse4.1`, `-msha`, `-mgfni`) behind `target_arch=='x64'`
- Ensure the darwin + arm64 combination compiles `ws_fallback.c` with no x86-specific flags

### 7. Create `.github/workflows/prebuild.yml`

CI workflow that:
1. Runs on ubuntu-latest, windows-latest, macos-latest (covers all 4 platform-arch combos; macos-latest is arm64)
2. Adds a macos-13 runner for darwin-x64 (macos-latest is arm64 since ~2024)
3. Installs NASM on Linux
4. Runs `npx prebuildify --strip --target=20.0.0 --target=22.0.0 --target=24.0.0`
5. Uploads prebuilds as artifacts
6. On tagged releases: downloads all artifacts, merges into `prebuilds/`, commits them to the repo (npm publish is done manually via `npm publish` after verifying the prebuilds)

### 8. Verify `.npmignore`

Ensure `prebuilds/` is NOT listed in `.npmignore`. Current `.npmignore` ignores `.github/`, `.claude/`, `test/`, `bench/`, `docs/`, `CONTRIBUTING.md`, `.gitignore` — prebuilds is not ignored. No change needed, but verify the `files` field in package.json includes it.

## What Does NOT Change

- All assembly files (ws_mask_asm.asm, ws_base64_asm.asm, ws_crc32_asm.asm, ws_utf8_asm.asm, ws_cpu.asm)
- ws_fast_api.cc (V8 C++ API binding)
- ws_fallback.c (C/SIMD fallback)
- ws_sha1_ni.c (SHA-1)
- test/index.js (test suite)
- bench/index.js (benchmarks)
- .github/workflows/ci.yml (existing CI)
- README.md, CHANGELOG.md, CONTRIBUTING.md

## Integration with ws

Users swap bufferutil for asm-bufferutil via npm overrides:

```json
{
  "overrides": {
    "bufferutil": "npm:asm-bufferutil@^1.0.0"
  }
}
```

This instructs npm to resolve any `require('bufferutil')` (including from within `ws`) to the asm-bufferutil package instead. Document this in README.

## Risks

- **V8 API breakage:** New Node.js major versions may change V8 C++ API surface. Mitigation: CI tests against Node nightly; the API surface used (FunctionCallbackInfo, Buffer::Data, FunctionTemplate) has been stable for years.
- **macOS arm64 C fallback performance:** No SIMD on arm64 in ws_fallback.c (it uses x86 intrinsics). The scalar/generic path will be slower than bufferutil's N-API + V8 optimized path on Apple Silicon. Acceptable for initial release; NEON intrinsics are future work.
- **Prebuild size:** 12 .node files (~115KB each) adds ~1.4MB to the npm tarball. Acceptable — bufferutil ships 5 prebuilds at similar size.
