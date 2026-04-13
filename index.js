'use strict';

/**
 * asm-bufferutil — Drop-in replacement for bufferutil
 *
 * Uses hand-written x86-64 assembly with SSE2 SIMD for WebSocket
 * frame masking/unmasking. API-compatible with bufferutil.
 *
 * Architecture:
 *
 *   ┌─────────────────────────────────────────────┐
 *   │  Node.js  (ws library)                      │
 *   │                                             │
 *   │  bufferUtil.mask(source, mask, out, off, len)│
 *   │  bufferUtil.unmask(buffer, mask)             │
 *   └───────────────┬───────────────────────────────┘
 *                   │  N-API boundary
 *   ┌───────────────▼───────────────────────────────┐
 *   │  ws_napi.c  (C glue layer)                   │
 *   │                                               │
 *   │  - Extracts Buffer pointers from V8 heap      │
 *   │  - Validates args, extracts offset/length     │
 *   │  - Calls assembly functions with raw pointers  │
 *   └───────────────┬───────────────────────────────┘
 *                   │  C calling convention (System V AMD64)
 *   ┌───────────────▼───────────────────────────────┐
 *   │  ws_mask_asm.asm  (x86-64 NASM)              │
 *   │                                               │
 *   │  SSE2 fast path:                              │
 *   │    - Broadcasts 4-byte mask → 128-bit XMM reg │
 *   │    - PXOR 16 bytes at a time                  │
 *   │                                               │
 *   │  Scalar fallback:                             │
 *   │    - XOR byte-by-byte for remaining 0-15      │
 *   └───────────────────────────────────────────────┘
 */

try {
  // Try to load the native addon
  const binding = require('./build/Release/asm_bufferutil.node');
  module.exports = binding;
} catch (e) {
  // Fallback to pure JS implementation (same as ws does internally)
  console.warn('asm-bufferutil: Native addon not available, using JS fallback');
  console.warn('  Reason:', e.message);

  module.exports = {
    mask(source, mask, output, offset, length) {
      for (let i = 0; i < length; i++) {
        output[offset + i] = source[i] ^ mask[i & 3];
      }
    },

    unmask(buffer, mask) {
      for (let i = 0; i < buffer.length; i++) {
        buffer[i] ^= mask[i & 3];
      }
    }
  };
}
