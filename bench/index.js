'use strict';

/**
 * Benchmark: Assembly SIMD vs bufferutil vs Pure JavaScript WebSocket operations
 *
 * Improvements over naive benchmarking:
 *   - Time-based iteration (minimum 1s per sample) instead of fixed counts
 *   - Multiple samples with median/min/max reporting
 *   - Proper warmup phase (500ms) to let V8 JIT compile hot paths
 *   - GC between tests (when --expose-gc is available)
 *   - All exported operations: mask, unmask, sha1, findHeader, base64Encode
 *   - Throughput (MB/s) alongside ops/s
 */

const crypto = require('crypto');

// ── Configuration ───────────────────────────────────────────────────────────

const WARMUP_MS = 500;
const SAMPLE_MS = 1000;
const SAMPLES = 5;

// ── Load implementations ────────────────────────────────────────────────────

let asmUtil;
try {
  asmUtil = require('../build/Release/asm_bufferutil.node');
  console.log('asm-bufferutil : native assembly (SIMD) \u2713');
  console.log('  cpuFeatures  : 0x' + asmUtil.cpuFeatures.toString(16));
  if (asmUtil.hasShaNi) console.log('  SHA-NI       : available');
} catch (e) {
  console.log('asm-bufferutil : not built \u2014 run `npm run build` first');
  asmUtil = null;
}

let buUtil;
try {
  buUtil = require('bufferutil');
  console.log('bufferutil     : native addon \u2713');
} catch (e) {
  console.log('bufferutil     : not installed');
  buUtil = null;
}

console.log();

// ── GC helper ───────────────────────────────────────────────────────────────

const canGC = typeof global.gc === 'function';
if (!canGC) {
  console.log('Tip: run with --expose-gc for more stable results\n');
}

function collectGarbage() {
  if (canGC) global.gc();
}

// ── Pure JS reference implementations ───────────────────────────────────────

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

// ── Benchmark engine ────────────────────────────────────────────────────────

/**
 * Run fn() in a tight loop for at least `durationMs` milliseconds.
 * Returns { ops, elapsed } where elapsed is in ms.
 */
function timedRun(fn, durationMs) {
  const deadline = process.hrtime.bigint() + BigInt(durationMs) * 1_000_000n;
  let ops = 0;
  while (process.hrtime.bigint() < deadline) {
    fn(); fn(); fn(); fn(); fn();
    fn(); fn(); fn(); fn(); fn();
    ops += 10;
  }
  const end = process.hrtime.bigint();
  const elapsed = Number(end - (deadline - BigInt(durationMs) * 1_000_000n)) / 1e6;
  return { ops, elapsed };
}

/**
 * Benchmark a function: warmup, then collect multiple samples.
 * Returns { median, min, max, samples[] } in ops/sec.
 */
function benchmark(fn) {
  // Warmup
  timedRun(fn, WARMUP_MS);

  const results = [];
  for (let i = 0; i < SAMPLES; i++) {
    const { ops, elapsed } = timedRun(fn, SAMPLE_MS);
    results.push((ops / elapsed) * 1000);
  }

  results.sort((a, b) => a - b);
  return {
    median: results[Math.floor(results.length / 2)],
    min: results[0],
    max: results[results.length - 1],
    samples: results
  };
}

// ── Formatting ──────────────────────────────────────────────────────────────

function fmtOps(n) {
  if (n === null) return '\u2014'.padStart(12);
  if (n >= 1e6) return (n / 1e6).toFixed(2).padStart(9) + 'M  ';
  if (n >= 1e3) return (n / 1e3).toFixed(1).padStart(9) + 'K  ';
  return n.toFixed(0).padStart(12);
}

function fmtThroughput(opsPerSec, payloadBytes) {
  if (opsPerSec === null) return '\u2014'.padStart(10);
  const mbps = (opsPerSec * payloadBytes) / (1024 * 1024);
  if (mbps >= 1024) return (mbps / 1024).toFixed(1).padStart(7) + ' GB/s';
  return mbps.toFixed(1).padStart(7) + ' MB/s';
}

function fmtSpeedup(asm, reference) {
  if (asm === null || reference === null) return '  \u2014  ';
  const ratio = asm / reference;
  const str = ratio.toFixed(2) + 'x';
  return ratio >= 1.0 ? str : str;
}

function fmtRange(result) {
  if (result === null) return '';
  const spread = ((result.max - result.min) / result.median * 100).toFixed(1);
  return `\u00b1${spread}%`;
}

// ── Payload sizes ───────────────────────────────────────────────────────────

const sizes = [
  { name: '64 B',   size: 64 },
  { name: '128 B',  size: 128 },     // GPR→SIMD boundary
  { name: '256 B',  size: 256 },
  { name: '384 B',  size: 384 },     // mid-SIMD transition zone
  { name: '512 B',  size: 512 },
  { name: '1 KB',   size: 1024 },
  { name: '16 KB',  size: 16384 },
  { name: '64 KB',  size: 65536 },
  { name: '256 KB', size: 262144 },
  { name: '1 MB',   size: 1048576 },
  { name: '4 MB',   size: 4194304 },
];

// ── Mask benchmark ──────────────────────────────────────────────────────────

console.log('=== WebSocket Mask ===');
console.log(
  'Size'.padEnd(10) +
  '  JS ops/s'.padEnd(14) +
  '  bufferutil'.padEnd(14) +
  '  ASM ops/s'.padEnd(14) +
  '  ASM MB/s'.padEnd(12) +
  '  vs BU'.padEnd(9) +
  '  spread'
);
console.log('\u2500'.repeat(80));

for (const { name, size } of sizes) {
  const source = crypto.randomBytes(size);
  const mask   = crypto.randomBytes(4);
  const output = Buffer.alloc(size);

  collectGarbage();
  const jsRes  = benchmark(() => jsUtil.mask(source, mask, output, 0, size));
  collectGarbage();
  const buRes  = buUtil ? benchmark(() => buUtil.mask(source, mask, output, 0, size)) : null;
  collectGarbage();
  const asmRes = asmUtil ? benchmark(() => asmUtil.mask(source, mask, output, 0, size)) : null;

  const ref = buRes ?? jsRes;
  console.log(
    name.padEnd(10) +
    fmtOps(jsRes.median) +
    fmtOps(buRes?.median ?? null) +
    fmtOps(asmRes?.median ?? null) +
    fmtThroughput(asmRes?.median ?? null, size).padStart(12) +
    fmtSpeedup(asmRes?.median ?? null, ref.median).padStart(9) +
    ('  ' + fmtRange(asmRes))
  );
}

// ── Unmask benchmark ────────────────────────────────────────────────────────

console.log('\n=== WebSocket Unmask ===');
console.log(
  'Size'.padEnd(10) +
  '  JS ops/s'.padEnd(14) +
  '  bufferutil'.padEnd(14) +
  '  ASM ops/s'.padEnd(14) +
  '  ASM MB/s'.padEnd(12) +
  '  vs BU'.padEnd(9) +
  '  spread'
);
console.log('\u2500'.repeat(80));

for (const { name, size } of sizes) {
  const mask = crypto.randomBytes(4);
  const buf  = crypto.randomBytes(size);

  collectGarbage();
  const jsRes  = benchmark(() => jsUtil.unmask(buf, mask));
  collectGarbage();
  const buRes  = buUtil ? benchmark(() => buUtil.unmask(buf, mask)) : null;
  collectGarbage();
  const asmRes = asmUtil ? benchmark(() => asmUtil.unmask(buf, mask)) : null;

  const ref = buRes ?? jsRes;
  console.log(
    name.padEnd(10) +
    fmtOps(jsRes.median) +
    fmtOps(buRes?.median ?? null) +
    fmtOps(asmRes?.median ?? null) +
    fmtThroughput(asmRes?.median ?? null, size).padStart(12) +
    fmtSpeedup(asmRes?.median ?? null, ref.median).padStart(9) +
    ('  ' + fmtRange(asmRes))
  );
}

// ── SHA-1 benchmark ─────────────────────────────────────────────────────────

if (asmUtil?.hasShaNi) {
  console.log('\n=== SHA-1 (SHA-NI vs crypto) ===');
  console.log(
    'Size'.padEnd(10) +
    '  crypto'.padEnd(14) +
    '  ASM ops/s'.padEnd(14) +
    '  ASM MB/s'.padEnd(12) +
    '  vs crypto'.padEnd(11) +
    '  spread'
  );
  console.log('\u2500'.repeat(65));

  // ws_sha1_ni supports up to 119 bytes (2 SHA-1 blocks, WebSocket handshake use)
  const shaSizes = [
    { name: '20 B',   size: 20 },
    { name: '36 B',   size: 36 },
    { name: '60 B',   size: 60 },   // typical Sec-WebSocket-Accept input
    { name: '100 B',  size: 100 },
  ];

  for (const { name, size } of shaSizes) {
    const data = crypto.randomBytes(size);

    collectGarbage();
    const cryptoRes = benchmark(() => crypto.createHash('sha1').update(data).digest());
    collectGarbage();
    const asmRes = benchmark(() => asmUtil.sha1(data));

    console.log(
      name.padEnd(10) +
      fmtOps(cryptoRes.median) +
      fmtOps(asmRes.median) +
      fmtThroughput(asmRes.median, size).padStart(12) +
      fmtSpeedup(asmRes.median, cryptoRes.median).padStart(11) +
      ('  ' + fmtRange(asmRes))
    );
  }
}

// ── Base64 benchmark ────────────────────────────────────────────────────────

if (asmUtil) {
  console.log('\n=== Base64 Encode (ASM vs Buffer.toString) ===');
  console.log(
    'Size'.padEnd(10) +
    '  JS ops/s'.padEnd(14) +
    '  ASM ops/s'.padEnd(14) +
    '  ASM MB/s'.padEnd(12) +
    '  vs JS'.padEnd(9) +
    '  spread'
  );
  console.log('\u2500'.repeat(65));

  const b64Sizes = [
    { name: '20 B',   size: 20 },
    { name: '256 B',  size: 256 },
    { name: '1 KB',   size: 1024 },
    { name: '16 KB',  size: 16384 },
  ];

  for (const { name, size } of b64Sizes) {
    const data = crypto.randomBytes(size);

    collectGarbage();
    const jsRes  = benchmark(() => data.toString('base64'));
    collectGarbage();
    const asmRes = benchmark(() => asmUtil.base64Encode(data));

    console.log(
      name.padEnd(10) +
      fmtOps(jsRes.median) +
      fmtOps(asmRes.median) +
      fmtThroughput(asmRes.median, size).padStart(12) +
      fmtSpeedup(asmRes.median, jsRes.median).padStart(9) +
      ('  ' + fmtRange(asmRes))
    );
  }
}

// ── Header search benchmark ─────────────────────────────────────────────────

if (asmUtil) {
  console.log('\n=== Header Search (findHeader) ===');
  console.log(
    'Size'.padEnd(10) +
    '  JS ops/s'.padEnd(14) +
    '  ASM ops/s'.padEnd(14) +
    '  vs JS'.padEnd(9) +
    '  spread'
  );
  console.log('\u2500'.repeat(55));

  const needle = Buffer.from('\r\n\r\n');
  const hdSizes = [
    { name: '256 B',  size: 256 },
    { name: '1 KB',   size: 1024 },
    { name: '4 KB',   size: 4096 },
    { name: '16 KB',  size: 16384 },
  ];

  for (const { name, size } of hdSizes) {
    // Place the needle near the end so the search does real work
    const data = crypto.randomBytes(size);
    data[size - 5] = 0x0d; // \r
    data[size - 4] = 0x0a; // \n
    data[size - 3] = 0x0d; // \r
    data[size - 2] = 0x0a; // \n

    collectGarbage();
    const jsRes  = benchmark(() => data.indexOf(needle));
    collectGarbage();
    const asmRes = benchmark(() => asmUtil.findHeader(data, needle));

    console.log(
      name.padEnd(10) +
      fmtOps(jsRes.median) +
      fmtOps(asmRes.median) +
      fmtSpeedup(asmRes.median, jsRes.median).padStart(9) +
      ('  ' + fmtRange(asmRes))
    );
  }
}

console.log('\n' + '\u2500'.repeat(80));
console.log('Config: warmup=' + WARMUP_MS + 'ms, sample=' + SAMPLE_MS + 'ms, samples=' + SAMPLES);
console.log('Median of ' + SAMPLES + ' samples shown. Spread = (max-min)/median.');
if (!canGC) console.log('Note: GC not exposed. Results may have higher variance.');
console.log();
