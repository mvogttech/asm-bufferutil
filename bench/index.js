'use strict';

/**
 * Benchmark: Assembly SSE2 vs bufferutil vs Pure JavaScript WebSocket masking
 *
 * Measures throughput for mask and unmask operations across
 * different payload sizes to show where SIMD acceleration
 * provides the most benefit.
 */

const crypto = require('crypto');

// Load assembly implementation
let asmUtil;
try {
  asmUtil = require('../build/Release/asm_bufferutil.node');
  console.log('asm-bufferutil : native assembly (SSE2) ✓');
} catch (e) {
  console.log('asm-bufferutil : not built — run `npm run build` first');
  asmUtil = null;
}

// Load upstream bufferutil for comparison
let buUtil;
try {
  buUtil = require('bufferutil');
  console.log('bufferutil     : native addon ✓');
} catch (e) {
  console.log('bufferutil     : not installed — run `npm install bufferutil` to include');
  buUtil = null;
}

console.log();

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

function bench(fn, iterations) {
  // Warmup
  for (let i = 0; i < Math.min(iterations, 100); i++) fn();

  const start = process.hrtime.bigint();
  for (let i = 0; i < iterations; i++) fn();
  const elapsed = Number(process.hrtime.bigint() - start) / 1e6; // ms

  return (iterations / elapsed) * 1000; // ops/sec
}

function fmtOps(n) {
  return n !== null ? n.toFixed(0).padStart(15) : '—'.padStart(15);
}

function fmtSpeedup(asm, reference) {
  if (asm === null || reference === null) return 'N/A';
  return (asm / reference).toFixed(2) + 'x';
}

const sizes = [
  { name: '64 B',   size: 64 },
  { name: '256 B',  size: 256 },
  { name: '1 KB',   size: 1024 },
  { name: '16 KB',  size: 16384 },
  { name: '64 KB',  size: 65536 },
  { name: '256 KB', size: 262144 },
  { name: '1 MB',   size: 1048576 },
];

// ── Mask ─────────────────────────────────────────────────────────────────────

console.log('=== WebSocket Mask Benchmark ===');
console.log('Payload Size  │ JS (ops/s)      │ bufferutil (ops/s) │ ASM (ops/s)      │ vs bufferutil');
console.log('──────────────┼─────────────────┼────────────────────┼──────────────────┼──────────────');

for (const { name, size } of sizes) {
  const source = crypto.randomBytes(size);
  const mask   = crypto.randomBytes(4);
  const output = Buffer.alloc(size);
  const iters  = Math.max(100, Math.floor(5_000_000 / size));

  const jsOps  = bench(() => jsUtil.mask(source, mask, output, 0, size), iters);
  const buOps  = buUtil  ? bench(() => buUtil.mask(source, mask, output, 0, size), iters) : null;
  const asmOps = asmUtil ? bench(() => asmUtil.mask(source, mask, output, 0, size), iters) : null;

  const vsRef = fmtSpeedup(asmOps, buOps ?? jsOps);

  console.log(
    `${name.padEnd(13)} │ ${fmtOps(jsOps)}   │ ${fmtOps(buOps)}     │ ${fmtOps(asmOps)}     │ ${vsRef}`
  );
}

// ── Unmask ───────────────────────────────────────────────────────────────────

console.log('\n=== WebSocket Unmask Benchmark ===');
console.log('Payload Size  │ JS (ops/s)      │ bufferutil (ops/s) │ ASM (ops/s)      │ vs bufferutil');
console.log('──────────────┼─────────────────┼────────────────────┼──────────────────┼──────────────');

for (const { name, size } of sizes) {
  const mask  = crypto.randomBytes(4);
  const iters = Math.max(100, Math.floor(5_000_000 / size));

  const jsOps  = bench(() => { const buf = crypto.randomBytes(size); jsUtil.unmask(buf, mask); }, iters);
  const buOps  = buUtil  ? bench(() => { const buf = crypto.randomBytes(size); buUtil.unmask(buf, mask); }, iters) : null;
  const asmOps = asmUtil ? bench(() => { const buf = crypto.randomBytes(size); asmUtil.unmask(buf, mask); }, iters) : null;

  const vsRef = fmtSpeedup(asmOps, buOps ?? jsOps);

  console.log(
    `${name.padEnd(13)} │ ${fmtOps(jsOps)}   │ ${fmtOps(buOps)}     │ ${fmtOps(asmOps)}     │ ${vsRef}`
  );
}

console.log('\nNote: "vs bufferutil" falls back to "vs JS" when bufferutil is not installed.');
console.log('ASM advantage grows with payload size due to SSE2 processing 16 bytes/cycle.\n');
