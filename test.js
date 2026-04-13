'use strict';

/**
 * Test suite for asm-bufferutil
 *
 * Verifies that the assembly masking implementation produces
 * identical results to the reference JavaScript implementation.
 */

const crypto = require('crypto');
const asmUtil = require('./index');

// Reference JS implementation for comparison
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

let passed = 0;
let failed = 0;

function assert(condition, message) {
  if (condition) {
    passed++;
    console.log(`  ✓ ${message}`);
  } else {
    failed++;
    console.error(`  ✗ ${message}`);
  }
}

function buffersEqual(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

// --- Test: mask function ---
console.log('\nmask() tests:');

// Small payload (< 16 bytes, scalar path only)
{
  const source = Buffer.from('Hello, World!');
  const mask = Buffer.from([0x12, 0x34, 0x56, 0x78]);
  const output1 = Buffer.alloc(source.length + 4);
  const output2 = Buffer.alloc(source.length + 4);
  const offset = 4;

  asmUtil.mask(source, mask, output1, offset, source.length);
  jsUtil.mask(source, mask, output2, offset, source.length);

  assert(
    buffersEqual(output1, output2),
    'Small payload (13 bytes) — scalar path'
  );
}

// Exact 16-byte payload (one SSE2 iteration, no scalar remainder)
{
  const source = Buffer.from('0123456789ABCDEF');
  const mask = Buffer.from([0xAA, 0xBB, 0xCC, 0xDD]);
  const output1 = Buffer.alloc(source.length);
  const output2 = Buffer.alloc(source.length);

  asmUtil.mask(source, mask, output1, 0, source.length);
  jsUtil.mask(source, mask, output2, 0, source.length);

  assert(
    buffersEqual(output1, output2),
    'Exact 16 bytes — single SSE2 pass'
  );
}

// 33-byte payload (2 SSE2 iterations + 1 scalar byte)
{
  const source = crypto.randomBytes(33);
  const mask = crypto.randomBytes(4);
  const output1 = Buffer.alloc(source.length);
  const output2 = Buffer.alloc(source.length);

  asmUtil.mask(source, mask, output1, 0, source.length);
  jsUtil.mask(source, mask, output2, 0, source.length);

  assert(
    buffersEqual(output1, output2),
    '33 bytes — SSE2 + scalar remainder'
  );
}

// Large payload (1 MB)
{
  const source = crypto.randomBytes(1024 * 1024);
  const mask = crypto.randomBytes(4);
  const output1 = Buffer.alloc(source.length);
  const output2 = Buffer.alloc(source.length);

  asmUtil.mask(source, mask, output1, 0, source.length);
  jsUtil.mask(source, mask, output2, 0, source.length);

  assert(
    buffersEqual(output1, output2),
    '1 MB payload — bulk SSE2'
  );
}

// With non-zero offset
{
  const source = crypto.randomBytes(50);
  const mask = crypto.randomBytes(4);
  const output1 = Buffer.alloc(100);
  const output2 = Buffer.alloc(100);
  const offset = 20;

  asmUtil.mask(source, mask, output1, offset, source.length);
  jsUtil.mask(source, mask, output2, offset, source.length);

  assert(
    buffersEqual(output1, output2),
    'Non-zero offset (20) with 50-byte payload'
  );
}

// --- Test: unmask function ---
console.log('\nunmask() tests:');

// Small in-place unmask
{
  const mask = Buffer.from([0x12, 0x34, 0x56, 0x78]);
  const buf1 = Buffer.from('Hello, World!');
  const buf2 = Buffer.from(buf1);

  asmUtil.unmask(buf1, mask);
  jsUtil.unmask(buf2, mask);

  assert(
    buffersEqual(buf1, buf2),
    'Small in-place unmask (13 bytes)'
  );
}

// Roundtrip: mask then unmask should return original
{
  const original = Buffer.from('The quick brown fox jumps over the lazy dog');
  const mask = crypto.randomBytes(4);
  const masked = Buffer.alloc(original.length);

  asmUtil.mask(original, mask, masked, 0, original.length);
  asmUtil.unmask(masked, mask);

  assert(
    buffersEqual(masked, original),
    'Roundtrip: mask → unmask recovers original'
  );
}

// Large roundtrip
{
  const original = crypto.randomBytes(1024 * 1024);
  const mask = crypto.randomBytes(4);
  const masked = Buffer.alloc(original.length);

  asmUtil.mask(original, mask, masked, 0, original.length);
  asmUtil.unmask(masked, mask);

  assert(
    buffersEqual(masked, original),
    'Large roundtrip (1 MB): mask → unmask'
  );
}

// Zero-length
{
  const source = Buffer.alloc(0);
  const mask = Buffer.from([0xFF, 0xFF, 0xFF, 0xFF]);
  const output = Buffer.alloc(0);

  asmUtil.mask(source, mask, output, 0, 0);
  assert(true, 'Zero-length mask does not crash');

  asmUtil.unmask(source, mask);
  assert(true, 'Zero-length unmask does not crash');
}

console.log(`\nResults: ${passed} passed, ${failed} failed\n`);
process.exit(failed > 0 ? 1 : 0);
