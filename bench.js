'use strict';

/**
 * Benchmark: Assembly SSE2 vs Pure JavaScript WebSocket masking
 *
 * Measures throughput for mask and unmask operations across
 * different payload sizes to show where SIMD acceleration
 * provides the most benefit.
 */

const crypto = require('crypto');

// Load assembly implementation
let asmUtil;
try {
  asmUtil = require('./build/Release/asm_bufferutil.node');
  console.log('Using: native assembly (SSE2) addon\n');
} catch (e) {
  console.log('Native addon not built. Run `npm run build` first.');
  console.log('Benchmarking JS fallback only.\n');
  asmUtil = null;
}

// Pure JS reference
const jsUtil = {
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

function bench(label, fn, iterations) {
  // Warmup
  for (let i = 0; i < Math.min(iterations, 100); i++) fn();

  const start = process.hrtime.bigint();
  for (let i = 0; i < iterations; i++) fn();
  const elapsed = Number(process.hrtime.bigint() - start) / 1e6; // ms

  return { label, elapsed, iterations, opsPerSec: (iterations / elapsed) * 1000 };
}

const sizes = [
  { name: '64 B', size: 64 },
  { name: '256 B', size: 256 },
  { name: '1 KB', size: 1024 },
  { name: '16 KB', size: 16384 },
  { name: '64 KB', size: 65536 },
  { name: '256 KB', size: 262144 },
  { name: '1 MB', size: 1048576 },
];

console.log('=== WebSocket Mask Benchmark ===');
console.log('Payload Size  │ JS (ops/s)      │ ASM (ops/s)     │ Speedup');
console.log('──────────────┼─────────────────┼─────────────────┼────────');

for (const { name, size } of sizes) {
  const source = crypto.randomBytes(size);
  const mask = crypto.randomBytes(4);
  const output = Buffer.alloc(size);

  // Scale iterations inversely with size
  const iters = Math.max(100, Math.floor(5000000 / size));

  const jsResult = bench('JS', () => {
    jsUtil.mask(source, mask, output, 0, size);
  }, iters);

  let asmResult = null;
  let speedup = 'N/A';

  if (asmUtil) {
    asmResult = bench('ASM', () => {
      asmUtil.mask(source, mask, output, 0, size);
    }, iters);
    speedup = (asmResult.opsPerSec / jsResult.opsPerSec).toFixed(1) + 'x';
  }

  const jsOps = jsResult.opsPerSec.toFixed(0).padStart(13);
  const asmOps = asmResult
    ? asmResult.opsPerSec.toFixed(0).padStart(13)
    : '—'.padStart(13);

  console.log(`${name.padEnd(13)} │ ${jsOps}   │ ${asmOps}   │ ${speedup}`);
}

console.log('\n=== WebSocket Unmask Benchmark ===');
console.log('Payload Size  │ JS (ops/s)      │ ASM (ops/s)     │ Speedup');
console.log('──────────────┼─────────────────┼─────────────────┼────────');

for (const { name, size } of sizes) {
  const mask = crypto.randomBytes(4);
  const iters = Math.max(100, Math.floor(5000000 / size));

  const jsResult = bench('JS', () => {
    const buf = crypto.randomBytes(size);
    jsUtil.unmask(buf, mask);
  }, iters);

  let asmResult = null;
  let speedup = 'N/A';

  if (asmUtil) {
    asmResult = bench('ASM', () => {
      const buf = crypto.randomBytes(size);
      asmUtil.unmask(buf, mask);
    }, iters);
    speedup = (asmResult.opsPerSec / jsResult.opsPerSec).toFixed(1) + 'x';
  }

  const jsOps = jsResult.opsPerSec.toFixed(0).padStart(13);
  const asmOps = asmResult
    ? asmResult.opsPerSec.toFixed(0).padStart(13)
    : '—'.padStart(13);

  console.log(`${name.padEnd(13)} │ ${jsOps}   │ ${asmOps}   │ ${speedup}`);
}

console.log('\nNote: ASM advantage grows with payload size due to SSE2');
console.log('processing 16 bytes/cycle vs JS 1 byte/cycle.\n');
