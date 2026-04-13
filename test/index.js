'use strict';

/**
 * Test suite for asm-bufferutil
 *
 * Verifies that the assembly masking implementation produces
 * identical results to the reference JavaScript implementation.
 */

const crypto = require('crypto');
const asmUtil = require('../index');

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

// --- Test: base64Encode function (if available) ---
if (typeof asmUtil.base64Encode === 'function') {
  console.log('\nbase64Encode() tests:');

  // RFC 4648 known-good vectors
  {
    const vectors = [
      { input: '',       expected: '' },
      { input: 'f',      expected: 'Zg==' },
      { input: 'fo',     expected: 'Zm8=' },
      { input: 'foo',    expected: 'Zm9v' },
      { input: 'foobar', expected: 'Zm9vYmFy' },
    ];

    for (const { input, expected } of vectors) {
      const buf = Buffer.from(input, 'ascii');
      const result = asmUtil.base64Encode(buf).toString('ascii');
      assert(result === expected, `base64("${input}") = "${expected}"`);
    }
  }

  // SHA-1 output (20 bytes) — the primary use case for ws handshake
  {
    const sha1Input = Buffer.from(
    'dGhlIHNhbXBsZSBub25jZTI1ODhFQUZBNS1BOTE0LTQ3REEtOTVDQS1DNUFCMERCODU4MTE=',
    'base64'
  );
  const sha1Hash = crypto.createHash('sha1').update(sha1Input).digest();
  const expected = sha1Hash.toString('base64');
  const result = asmUtil.base64Encode(sha1Hash).toString('ascii');
  assert(result === expected, 'base64(SHA-1 20B hash) matches Node crypto reference');
}

// Large buffer — exercises AVX2 multi-iteration path (if cpu_tier >= 2)
{
  const input = crypto.randomBytes(300);
  const expected = input.toString('base64');
  const result = asmUtil.base64Encode(input).toString('ascii');
  assert(result === expected, 'base64(300 random bytes) matches Node reference');
  }
}

// --- Test: NT-store path (mask/unmask with >= 256KB) ---
console.log('\nmask() NT-store path tests (>= 256KB):');

{
  const source = crypto.randomBytes(512 * 1024);
  const mask = crypto.randomBytes(4);
  const output1 = Buffer.alloc(source.length);
  const output2 = Buffer.alloc(source.length);

  asmUtil.mask(source, mask, output1, 0, source.length);
  jsUtil.mask(source, mask, output2, 0, source.length);

  assert(buffersEqual(output1, output2), '512 KB mask — NT-store path produces correct output');
}

{
  const original = crypto.randomBytes(512 * 1024);
  const mask = crypto.randomBytes(4);
  const masked = Buffer.alloc(original.length);

  asmUtil.mask(original, mask, masked, 0, original.length);
  asmUtil.unmask(masked, mask);

  assert(buffersEqual(masked, original), '512 KB roundtrip (NT path): mask → unmask recovers original');
}

// NT prologue mask-cycling tests — non-zero offset forces dest into a
// misaligned position, exercising the byte-by-byte alignment prologue.
// A bug here produces silent data corruption (wrong mask bytes in the
// first 1-63 bytes of output), caught by comparison with JS reference.
{
  const source = crypto.randomBytes(512 * 1024);
  const mask = Buffer.from([0x11, 0x22, 0x33, 0x44]);
  const output1 = Buffer.alloc(source.length + 1);
  const output2 = Buffer.alloc(source.length + 1);

  asmUtil.mask(source, mask, output1, 1, source.length);
  jsUtil.mask(source, mask, output2, 1, source.length);

  assert(buffersEqual(output1, output2), '512 KB mask, offset=1 — NT prologue mask cycling');
}

{
  const source = crypto.randomBytes(512 * 1024);
  const mask = Buffer.from([0xAA, 0xBB, 0xCC, 0xDD]);
  const output1 = Buffer.alloc(source.length + 3);
  const output2 = Buffer.alloc(source.length + 3);

  asmUtil.mask(source, mask, output1, 3, source.length);
  jsUtil.mask(source, mask, output2, 3, source.length);

  assert(buffersEqual(output1, output2), '512 KB mask, offset=3 — NT prologue mask cycling (3-byte rotation)');
}

{
  // Unmask: slice the buffer by 1 to force misaligned rdi in ws_unmask NT path
  const original = crypto.randomBytes(512 * 1024);
  const mask = Buffer.from([0x12, 0x34, 0x56, 0x78]);
  const padded = Buffer.alloc(original.length + 1);
  original.copy(padded, 1);                  // data starts at byte 1

  const masked1 = Buffer.from(padded);       // copy for asm path
  const masked2 = Buffer.from(padded);       // copy for JS  reference

  // mask only the payload region (offset 1..length)
  const maskSlice1 = masked1.subarray(1);
  const maskSlice2 = masked2.subarray(1);

  asmUtil.unmask(maskSlice1, mask);
  jsUtil.unmask(maskSlice2, mask);

  assert(buffersEqual(maskSlice1, maskSlice2), '512 KB unmask, misaligned buffer — NT prologue mask cycling');
}

// --- Test: cpuFeatures bitmask (if available) ---
if (typeof asmUtil.cpuFeatures === 'number') {
  console.log('\ncpuFeatures bitmask:');

  {
    assert(typeof asmUtil.cpuFeatures === 'number', 'cpuFeatures is a number');
    assert(asmUtil.cpuFeatures >= 0 && asmUtil.cpuFeatures <= 0xFF, 'cpuFeatures is in valid range');
    const bits = [];
    if (asmUtil.cpuFeatures & 1) bits.push('GFNI');
    if (asmUtil.cpuFeatures & 2) bits.push('PCLMULQDQ');
    if (asmUtil.cpuFeatures & 4) bits.push('BMI2');
    if (asmUtil.cpuFeatures & 8)  bits.push('LZCNT');
    if (asmUtil.cpuFeatures & 16) bits.push('VBMI');
    console.log(`  (detected: 0x${asmUtil.cpuFeatures.toString(16).padStart(2,'0')} = [${bits.join(', ') || 'none'}])`);
  }
}

console.log(`\nResults: ${passed} passed, ${failed} failed\n`);
process.exit(failed > 0 ? 1 : 0);
