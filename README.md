# asm-bufferutil

[![CI](https://github.com/mvogttech/asm-bufferutil/actions/workflows/ci.yml/badge.svg)](https://github.com/mvogttech/asm-bufferutil/actions/workflows/ci.yml)
[![npm version](https://img.shields.io/npm/v/asm-bufferutil.svg)](https://www.npmjs.com/package/asm-bufferutil)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**WebSocket acceleration in hand-written x86-64 assembly with tiered SIMD dispatch (AVX-512 / AVX2 / SSE2).**

A drop-in replacement for [`bufferutil`](https://github.com/websockets/bufferutil) — the native addon that makes the [`ws`](https://github.com/websockets/ws) WebSocket library fast. Instead of C, the hot paths are written in NASM assembly with multi-tier SIMD vectorization, non-temporal memory paths for large payloads, and opmask branchless tails on AVX-512.

## Why?

The WebSocket protocol (RFC 6455 §5.3) requires that every client-to-server frame be masked with a 4-byte key via XOR. This is a tight loop that runs on every single message. The `ws` library delegates this to `bufferutil`, which implements it in C. This project replaces that C with hand-tuned assembly that adapts to your CPU's capabilities at runtime.

## Performance

Benchmarked on AMD Ryzen 9 7950X3D (Zen 4, AVX-512) vs `bufferutil` (C):

| Operation | Speedup vs bufferutil | Peak throughput |
|-----------|----------------------|-----------------|
| mask      | 1.1–1.5×             | 55 GB/s         |
| unmask    | 1.1–1.7×             | 90 GB/s         |
| batch unmask (64B frames) | 6–10× | —          |

Additional operations not in bufferutil:

| Operation | vs Node.js built-in | Notes |
|-----------|-------------------|-------|
| SHA-1 (SHA-NI) | 2.3× vs `crypto.createHash` | Hardware SHA-NI, ≤119 bytes |
| Base64 encode | — | VBMI2 VPMULTISHIFTQB + VPERMB pipeline |
| Header search | — | AVX-512 VPCMPEQB first+last byte filter |
| CRC-32C | — | PCLMULQDQ 4-way parallel folding |
| UTF-8 validation | — | SIMD ASCII fast path + scalar state machine |

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Node.js  (your app, or ws internals)                        │
│                                                              │
│  const util = require('asm-bufferutil');                      │
│  util.mask(source, mask, output, offset, length);            │
│  util.unmask(buffer, mask);                                  │
│  util.sha1(data);            // SHA-NI hardware acceleration │
│  util.base64Encode(data);    // SIMD base64                  │
│  util.findHeader(buf, needle);                               │
│  util.utf8Validate(buf);     // SIMD UTF-8 validation        │
│  util.batchUnmask(data, offsets, lengths, masks, count);     │
└────────────────────┬─────────────────────────────────────────┘
                     │  Direct V8 C++ API (zero N-API dispatch overhead)
┌────────────────────▼─────────────────────────────────────────┐
│  ws_fast_api.cc  —  V8 C++ API bridge                        │
│                                                              │
���  • node::Buffer::Data() for zero-copy pointer extraction     │
│  ��� Batch operations: C++ loop with zero V8 API calls inside  │
│  • Multi-buffer parallel: ws_unmask4/ws_mask4 for 4 frames   │
└─────────────���──────┬─────────────────────────────────────────┘
                     │  System V AMD64 calling convention
┌────────────────────▼─────────────────────────────────────────┐
│  Assembly layer  (NASM, Linux x86-64)                        │
│                                                              │
│  ws_cpu.asm        — CPUID feature detection + cache sizing  │
│                      cpu_tier: 0=scalar, 1=SSE2, 2=AVX2,    │
│                                3=AVX-512F+BW                 │
│                      cpu_features bitmask: GFNI, PCLMULQDQ,  │
│                        BMI2, LZCNT, VBMI, AMD, VBMI2        │
│                      nt_threshold: 50% of L3 cache           │
│                                                              │
│  ws_mask_asm.asm   — Mask/unmask with tiered dispatch:       │
│                      • GPR 4× unroll (< 128B)               │
│                      • AVX-512: 512B/iter, opmask tail,      │
│                        alignment preamble, dual-stream unmask │
│                      • AVX2: 128B/iter, aligned stores       │
│                      • SSE2: 64B/iter fallback               │
│                      • NT-store paths (> L3/2 threshold)     │
│                      • ws_unmask4/ws_mask4: 4-frame parallel  │
│                      • ws_find_header: VPCMPEQB wide search   │
│                      • ws_mask_gfni: GFNI experiment baseline │
│                                                              │
│  ws_base64_asm.asm — Base64 encode with dispatch:            │
│                      • AVX-512 VBMI2: VPMULTISHIFTQB+VPERMB  │
│                      • AVX-512 VBMI: VPERMB LUT              │
│                      • AVX2: Klomp/Muła VPSHUFB method       │
│                      • SSE2 / scalar fallback                │
│                                                              │
│  ws_crc32_asm.asm  — CRC-32C:                               │
│                      • PCLMULQDQ 4-way folding (≥ 256B)      │
│                      • SSE4.2 CRC32 instruction (< 256B)     │
│                                                              │
│  ws_utf8_asm.asm   — UTF-8 validation:                       │
│                      • AVX-512: 64B ASCII fast check          │
│                      • AVX2: 32B ASCII fast check             │
│                      • Scalar state machine (non-ASCII)       │
│                                                              │
│  ws_sha1_ni.c      — SHA-1 via Intel SHA-NI intrinsics       │
│                      (≤ 119 bytes, WebSocket handshake use)   │
│                                                              │
│  ws_fallback.c     — C/SIMD fallback (Windows/macOS)         │
│                      AVX2 → SSE2 → scalar dispatch            │
└──────────────────────────────────────────────────────────────┘
```

## How the masking works

WebSocket masking is deceptively simple. Given a payload and a 4-byte mask key:

```
masked[i] = payload[i] XOR mask[i % 4]
```

In pure JavaScript, this is a byte-at-a-time loop. In our assembly:

1. **Broadcast**: `VPBROADCASTD` replicates the 4-byte mask across a 512-bit ZMM register (64 bytes of mask).
2. **Alignment preamble**: An opmask partial store aligns the destination to a 64-byte cache line boundary, eliminating split-line penalties.
3. **Bulk XOR**: 8× unrolled `VPXORD` processes 512 bytes per iteration with interleaved load-XOR-store scheduling.
4. **Opmask tail**: `BZHI` builds a bitmask for the remaining 0–63 bytes; `vmovdqu8{k1}` handles the tail with zero branches.
5. **NT path**: For payloads exceeding 50% of L3 cache, switches to non-temporal stores (`VMOVNTDQ`) to avoid polluting the cache hierarchy.

## Build

Prerequisites: **Linux x86-64** with `nasm` for assembly SIMD paths. On Windows and macOS, the C fallback (`ws_fallback.c`) provides AVX2/SSE2/scalar dispatch automatically.

```bash
# Install NASM (Ubuntu/Debian)
sudo apt install nasm

# Build the native addon
npm install
npm run build

# Run tests (89 tests)
npm test

# Run benchmarks
npm run bench
```

Requires Node.js ≥ 20 and `node-gyp`.

## Usage

### Standalone

```javascript
const bufferUtil = require("asm-bufferutil");
const crypto = require("crypto");

const payload = Buffer.from("Hello WebSocket!");
const mask = crypto.randomBytes(4);
const output = Buffer.alloc(payload.length);

// Mask
bufferUtil.mask(payload, mask, output, 0, payload.length);

// Unmask (in-place)
bufferUtil.unmask(output, mask);
// output now equals payload

// SHA-1 (hardware-accelerated on CPUs with SHA-NI)
const hash = bufferUtil.sha1(Buffer.from("input data"));

// Base64 encode
const b64 = bufferUtil.base64Encode(hash);

// UTF-8 validation
const valid = bufferUtil.utf8Validate(Buffer.from("こんにちは"));

// Batch unmask (packed buffer API — zero V8 overhead in inner loop)
bufferUtil.batchUnmask(data, offsets, lengths, masks, count);
```

### As a drop-in for ws

The `ws` library checks for `bufferutil` at startup. You can redirect it:

```javascript
// Option 1: Package aliasing in package.json
{
  "dependencies": {
    "bufferutil": "npm:asm-bufferutil@1.0.0"
  }
}

// Option 2: Module resolution override
// In your entry point, before requiring ws:
const Module = require('module');
const originalResolve = Module._resolveFilename;
Module._resolveFilename = function(request, ...args) {
  if (request === 'bufferutil') {
    return require.resolve('asm-bufferutil');
  }
  return originalResolve.call(this, request, ...args);
};

const WebSocket = require('ws');
// ws now uses your assembly masking!
```

## How this compares to bufferutil

| Aspect           | bufferutil                       | asm-bufferutil                          |
| ---------------- | -------------------------------- | --------------------------------------- |
| Language         | C                                | x86-64 Assembly (NASM)                  |
| SIMD             | Compiler decides                 | Explicit AVX-512 / AVX2 / SSE2 tiering |
| Masking strategy | 32-bit XOR in C loop             | 512-bit VPXORD (16× wider)              |
| V8 bridge        | N-API                            | Direct V8 C++ API (lower overhead)      |
| Batch API        | None                             | Packed buffer, zero V8 calls in loop    |
| Extra operations | mask, unmask                     | + SHA-1, base64, CRC-32C, UTF-8, findHeader |
| NT stores        | No                               | Auto for payloads > 50% L3             |
| Portability      | Any platform with C compiler     | Linux x86-64 (C fallback elsewhere)    |

## CPU feature detection

At module load, `_init_cpu_features()` runs CPUID to detect:

- **cpu_tier**: 0 (scalar), 1 (SSE2), 2 (AVX2), 3 (AVX-512F+BW)
- **cpu_features**: GFNI, PCLMULQDQ, BMI2, LZCNT, VBMI, VBMI2, AMD vendor
- **nt_threshold**: 50% of L3 cache size (auto-detected via cache topology CPUID leaves)

All dispatch is runtime — a single binary adapts to the host CPU.

## Relevant to Meteor/DDP

If you're running Meteor.js, every DDP message (method calls, subscriptions, collection updates) goes through WebSocket framing. On a busy system with hundreds of concurrent connections, the masking loop runs thousands of times per second. Shaving microseconds here compounds into meaningful CPU savings.

## File structure

```
asm-bufferutil/
├── src/
│   ├── ws_fast_api.cc          # Direct V8 C++ API bridge
│   ├── ws_napi.c               # Legacy N-API bridge
│   ├── ws_sha1_ni.c            # SHA-1 with Intel SHA-NI intrinsics
│   ├── ws_fallback.c           # C/SIMD fallback (Windows/macOS)
│   ├── ws_mask_asm.asm         # Mask/unmask + findHeader (AVX-512/AVX2/SSE2/GPR)
│   ├── ws_base64_asm.asm       # Base64 encode (VBMI2/VBMI/AVX2/SSE2/scalar)
│   ├── ws_crc32_asm.asm        # CRC-32C (PCLMULQDQ folding / SSE4.2)
│   ├── ws_utf8_asm.asm         # UTF-8 validation (AVX-512/AVX2 ASCII + scalar)
│   ├── ws_cpu.asm              # CPUID feature detection + cache topology
│   └── websocket_server.asm    # WebSocket server-side frame assembly
├── test/
│   ├── index.js                # Correctness test suite (89 tests)
│   ├── crc32.c                 # C-level CRC-32C test harness
│   └── client.html             # Browser WebSocket test client
├── bench/
│   └── index.js                # Time-based benchmarks (all operations)
├── .github/workflows/
│   ├── ci.yml                  # CI: build + test
│   └── benchmark.yml           # Benchmark with artifact upload
├── binding.gyp                 # node-gyp build config (NASM actions)
├── index.js                    # JS entry point with native/fallback dispatch
├── package.json
├── CHANGELOG.md
├── CONTRIBUTING.md
└── README.md
```

## License

MIT
