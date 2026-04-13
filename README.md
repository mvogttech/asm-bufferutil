# asm-bufferutil

[![CI](https://github.com/mvogttech/asm-bufferutil/actions/workflows/ci.yml/badge.svg)](https://github.com/mvogttech/asm-bufferutil/actions/workflows/ci.yml)
[![npm version](https://img.shields.io/npm/v/asm-bufferutil.svg)](https://www.npmjs.com/package/asm-bufferutil)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**WebSocket frame masking in hand-written x86-64 assembly with SSE2 SIMD.**

A drop-in replacement for [`bufferutil`](https://github.com/websockets/bufferutil) — the native addon that makes the [`ws`](https://github.com/websockets/ws) WebSocket library fast. Instead of C, the hot path is written in NASM assembly with SSE2 vectorized XOR operations.

## Why?

The WebSocket protocol (RFC 6455 §5.3) requires that every client-to-server frame be masked with a 4-byte key via XOR. This is a tight loop that runs on every single message. The `ws` library delegates this to `bufferutil`, which implements it in C. This project replaces that C with hand-tuned assembly.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Node.js  (your app, or ws internals)               │
│                                                     │
│  const util = require('asm-bufferutil');             │
│  util.mask(source, mask, output, offset, length);   │
│  util.unmask(buffer, mask);                         │
└───────────────────┬─────────────────────────────────┘
                    │  N-API (ABI-stable across Node versions)
┌───────────────────▼─────────────────────────────────┐
│  ws_napi.c  —  C glue layer                         │
│                                                     │
│  • Extracts raw pointers from V8 Buffer objects     │
│  • Zero-copy: operates directly on V8 heap memory   │
│  • Passes pointers + lengths to assembly via         │
│    System V AMD64 calling convention                 │
└───────────────────┬─────────────────────────────────┘
                    │  Function call (no FFI overhead)
┌───────────────────▼─────────────────────────────────┐
│  ws_mask_asm.asm  —  x86-64 NASM                    │
│                                                     │
│  SSE2 fast path (16 bytes/cycle):                   │
│    1. Load 4-byte mask into XMM register            │
│    2. PSHUFD to broadcast across 128 bits           │
│    3. MOVDQU + PXOR + MOVDQU in a loop              │
│                                                     │
│  Scalar fallback (1 byte/cycle):                    │
│    XOR byte-by-byte for the 0-15 byte remainder     │
└─────────────────────────────────────────────────────┘
```

## How the masking actually works

WebSocket masking is deceptively simple. Given a payload and a 4-byte mask key:

```
masked[i] = payload[i] XOR mask[i % 4]
```

In pure JavaScript, this is a byte-at-a-time loop. In our assembly:

1. **Broadcast**: Take the 4-byte mask `[A, B, C, D]` and replicate it 4× into a 128-bit SSE register: `[A,B,C,D,A,B,C,D,A,B,C,D,A,B,C,D]`
2. **SIMD XOR**: Load 16 payload bytes, `PXOR` with the mask register, store result. One instruction masks 16 bytes.
3. **Cleanup**: Handle the 0-15 leftover bytes with scalar XOR.

Since the mask repeats every 4 bytes and 16 is a multiple of 4, the broadcast trick works perfectly — no alignment bookkeeping needed.

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

| Aspect           | bufferutil                       | asm-bufferutil            |
| ---------------- | -------------------------------- | ------------------------- |
| Language         | C                                | x86-64 Assembly           |
| SIMD             | Compiler decides (often uses it) | Explicit SSE2, guaranteed |
| Masking strategy | 32-bit XOR in C loop             | 128-bit PXOR (4× wider)   |
| N-API version    | Same                             | Same                      |
| API              | `mask()`, `unmask()`             | `mask()`, `unmask()`      |
| Portability      | Any platform with C compiler     | Linux x86-64 only         |

## Relevant to Meteor/DDP

If you're running Meteor.js, every DDP message (method calls, subscriptions, collection updates) goes through WebSocket framing. On a busy system with hundreds of concurrent connections, the masking loop runs thousands of times per second. Shaving microseconds here compounds into meaningful CPU savings.

To integrate with Meteor's internal WebSocket handling:

```javascript
// server/startup.js
// Meteor uses sockjs by default, but if using raw ws:
import { WebApp } from "meteor/webapp";

// The ws package inside Meteor will pick up bufferutil
// if it's in node_modules. Use the package aliasing approach.
```

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

## License

MIT
