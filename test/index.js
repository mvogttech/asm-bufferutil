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

// --- Test: batchUnmask function (packed buffer API) ---
if (typeof asmUtil.batchUnmask === 'function') {
  console.log('\nbatchUnmask() tests:');

  // Basic batch unmask with known values
  {
    // Pack two frames: [0x01,0x02,0x03] at offset 0, [0x10,0x20,0x30,0x40] at offset 3
    const data = Buffer.from([0x01, 0x02, 0x03, 0x10, 0x20, 0x30, 0x40]);
    const offsets = Buffer.alloc(8);
    offsets.writeUInt32LE(0, 0);
    offsets.writeUInt32LE(3, 4);
    const lengths = Buffer.alloc(8);
    lengths.writeUInt32LE(3, 0);
    lengths.writeUInt32LE(4, 4);
    const masks = Buffer.from([0xAA, 0xBB, 0xCC, 0xDD, 0x11, 0x22, 0x33, 0x44]);

    asmUtil.batchUnmask(data, offsets, lengths, masks, 2);

    assert(data[0] === (0x01 ^ 0xAA) && data[1] === (0x02 ^ 0xBB) && data[2] === (0x03 ^ 0xCC),
      'Batch unmask: first frame correct');
    assert(data[3] === (0x10 ^ 0x11) && data[4] === (0x20 ^ 0x22) && data[5] === (0x30 ^ 0x33) && data[6] === (0x40 ^ 0x44),
      'Batch unmask: second frame correct');
  }

  // Batch unmask matches individual unmask (50 frames packed)
  {
    const count = 50;
    const frameSizes = [];
    let totalSize = 0;
    for (let i = 0; i < count; i++) {
      const size = 10 + Math.floor(Math.random() * 200);
      frameSizes.push(size);
      totalSize += size;
    }

    const data = crypto.randomBytes(totalSize);
    const refData = Buffer.from(data);
    const offsets = Buffer.alloc(count * 4);
    const lengths = Buffer.alloc(count * 4);
    const masks = crypto.randomBytes(count * 4);

    let off = 0;
    for (let i = 0; i < count; i++) {
      offsets.writeUInt32LE(off, i * 4);
      lengths.writeUInt32LE(frameSizes[i], i * 4);
      off += frameSizes[i];
    }

    // Individual unmask on reference
    for (let i = 0; i < count; i++) {
      const o = offsets.readUInt32LE(i * 4);
      const l = lengths.readUInt32LE(i * 4);
      const slice = refData.subarray(o, o + l);
      asmUtil.unmask(slice, masks.subarray(i * 4, i * 4 + 4));
    }

    // Batch unmask
    asmUtil.batchUnmask(data, offsets, lengths, masks, count);

    assert(buffersEqual(data, refData), 'Batch unmask (50 frames) matches individual unmask');
  }

  // Empty batch
  {
    asmUtil.batchUnmask(Buffer.alloc(0), Buffer.alloc(0), Buffer.alloc(0), Buffer.alloc(0), 0);
    assert(true, 'Empty batch unmask does not crash');
  }
}

// --- Test: batchMask function (packed buffer API) ---
if (typeof asmUtil.batchMask === 'function') {
  console.log('\nbatchMask() tests:');

  // Batch mask matches individual mask (50 frames packed)
  {
    const count = 50;
    const frameSizes = [];
    let totalSize = 0;
    for (let i = 0; i < count; i++) {
      const size = 10 + Math.floor(Math.random() * 200);
      frameSizes.push(size);
      totalSize += size;
    }

    const src = crypto.randomBytes(totalSize);
    const dst = Buffer.alloc(totalSize);
    const refDst = Buffer.alloc(totalSize);
    const offsets = Buffer.alloc(count * 4);
    const lengths = Buffer.alloc(count * 4);
    const masks = crypto.randomBytes(count * 4);

    let off = 0;
    for (let i = 0; i < count; i++) {
      offsets.writeUInt32LE(off, i * 4);
      lengths.writeUInt32LE(frameSizes[i], i * 4);
      off += frameSizes[i];
    }

    // Individual mask on reference
    for (let i = 0; i < count; i++) {
      const o = offsets.readUInt32LE(i * 4);
      const l = lengths.readUInt32LE(i * 4);
      asmUtil.mask(src.subarray(o, o + l), masks.subarray(i * 4, i * 4 + 4), refDst, o, l);
    }

    // Batch mask
    asmUtil.batchMask(src, dst, offsets, lengths, masks, count);

    assert(buffersEqual(dst, refDst), 'Batch mask (50 frames) matches individual mask');
  }
}

// --- Test: maskGfni function (GFNI experiment baseline) ---
if (typeof asmUtil.maskGfni === 'function') {
  console.log('\nmaskGfni() tests (GFNI experiment):');

  // maskGfni should produce identical output to mask for all sizes
  {
    const testSizes = [0, 1, 3, 13, 16, 33, 64, 127, 128, 255, 256, 1024, 65536];
    for (const size of testSizes) {
      const source = crypto.randomBytes(size);
      const mask = crypto.randomBytes(4);
      const out1 = Buffer.alloc(size);
      const out2 = Buffer.alloc(size);

      asmUtil.mask(source, mask, out1, 0, size);
      asmUtil.maskGfni(source, mask, out2, 0, size);

      assert(
        buffersEqual(out1, out2),
        `maskGfni matches mask for ${size} bytes`
      );
    }
  }

  // maskGfni with non-zero offset
  {
    const source = crypto.randomBytes(200);
    const mask = crypto.randomBytes(4);
    const out1 = Buffer.alloc(250);
    const out2 = Buffer.alloc(250);

    asmUtil.mask(source, mask, out1, 37, source.length);
    asmUtil.maskGfni(source, mask, out2, 37, source.length);

    assert(
      buffersEqual(out1, out2),
      'maskGfni matches mask with non-zero offset (37)'
    );
  }
}

// --- Test: utf8Validate function ---
if (typeof asmUtil.utf8Validate === 'function') {
  console.log('\nutf8Validate() tests:');

  // Valid UTF-8: ASCII
  assert(asmUtil.utf8Validate(Buffer.from('Hello, World!')), 'ASCII is valid UTF-8');

  // Valid UTF-8: empty buffer
  assert(asmUtil.utf8Validate(Buffer.from('')), 'Empty buffer is valid UTF-8');

  // Valid UTF-8: 2-byte sequences (Latin, Cyrillic, etc.)
  assert(asmUtil.utf8Validate(Buffer.from('\u00e9\u00e8\u00ea')), '2-byte chars (accented Latin) are valid');

  // Valid UTF-8: 3-byte sequences (CJK)
  assert(asmUtil.utf8Validate(Buffer.from('\u3053\u3093\u306b\u3061\u306f')), 'Japanese (3-byte) is valid UTF-8');

  // Valid UTF-8: 4-byte sequences (emoji)
  assert(asmUtil.utf8Validate(Buffer.from('\ud83c\udf89\ud83d\ude80')), '4-byte emoji is valid UTF-8');

  // Valid UTF-8: mixed ASCII and multi-byte
  assert(
    asmUtil.utf8Validate(Buffer.from('Hello \u00e9\u00e8 \u3053\u3093 \ud83c\udf89 World!')),
    'Mixed ASCII + multi-byte is valid UTF-8'
  );

  // Valid UTF-8: boundary values
  assert(asmUtil.utf8Validate(Buffer.from([0x00])), 'U+0000 (NUL) is valid');
  assert(asmUtil.utf8Validate(Buffer.from([0x7F])), 'U+007F (DEL) is valid');
  assert(asmUtil.utf8Validate(Buffer.from([0xC2, 0x80])), 'U+0080 is valid');
  assert(asmUtil.utf8Validate(Buffer.from([0xDF, 0xBF])), 'U+07FF is valid');
  assert(asmUtil.utf8Validate(Buffer.from([0xE0, 0xA0, 0x80])), 'U+0800 is valid');
  assert(asmUtil.utf8Validate(Buffer.from([0xEF, 0xBF, 0xBF])), 'U+FFFF is valid');
  assert(asmUtil.utf8Validate(Buffer.from([0xF0, 0x90, 0x80, 0x80])), 'U+10000 is valid');
  assert(asmUtil.utf8Validate(Buffer.from([0xF4, 0x8F, 0xBF, 0xBF])), 'U+10FFFF is valid');

  // Valid UTF-8: just below surrogate range
  assert(asmUtil.utf8Validate(Buffer.from([0xED, 0x9F, 0xBF])), 'U+D7FF (just below surrogates) is valid');

  // Valid UTF-8: just above surrogate range
  assert(asmUtil.utf8Validate(Buffer.from([0xEE, 0x80, 0x80])), 'U+E000 (just above surrogates) is valid');

  // Invalid: bare continuation byte
  assert(!asmUtil.utf8Validate(Buffer.from([0x80])), 'Bare continuation byte 0x80 is invalid');
  assert(!asmUtil.utf8Validate(Buffer.from([0xBF])), 'Bare continuation byte 0xBF is invalid');

  // Invalid: overlong 2-byte encoding (C0 80 = U+0000, C1 BF = U+007F)
  assert(!asmUtil.utf8Validate(Buffer.from([0xC0, 0x80])), 'Overlong 2-byte (C0 80) is invalid');
  assert(!asmUtil.utf8Validate(Buffer.from([0xC1, 0xBF])), 'Overlong 2-byte (C1 BF) is invalid');

  // Invalid: overlong 3-byte encoding (E0 80 80 = U+0000)
  assert(!asmUtil.utf8Validate(Buffer.from([0xE0, 0x80, 0x80])), 'Overlong 3-byte (E0 80 80) is invalid');
  assert(!asmUtil.utf8Validate(Buffer.from([0xE0, 0x9F, 0xBF])), 'Overlong 3-byte (E0 9F BF) is invalid');

  // Invalid: overlong 4-byte encoding (F0 80 80 80 = U+0000)
  assert(!asmUtil.utf8Validate(Buffer.from([0xF0, 0x80, 0x80, 0x80])), 'Overlong 4-byte (F0 80 80 80) is invalid');
  assert(!asmUtil.utf8Validate(Buffer.from([0xF0, 0x8F, 0xBF, 0xBF])), 'Overlong 4-byte (F0 8F BF BF) is invalid');

  // Invalid: surrogates (U+D800-U+DFFF)
  assert(!asmUtil.utf8Validate(Buffer.from([0xED, 0xA0, 0x80])), 'Surrogate U+D800 is invalid');
  assert(!asmUtil.utf8Validate(Buffer.from([0xED, 0xAF, 0xBF])), 'Surrogate U+DBFF is invalid');
  assert(!asmUtil.utf8Validate(Buffer.from([0xED, 0xB0, 0x80])), 'Surrogate U+DC00 is invalid');
  assert(!asmUtil.utf8Validate(Buffer.from([0xED, 0xBF, 0xBF])), 'Surrogate U+DFFF is invalid');

  // Invalid: out of range (> U+10FFFF)
  assert(!asmUtil.utf8Validate(Buffer.from([0xF4, 0x90, 0x80, 0x80])), 'Out of range (F4 90 80 80) is invalid');
  assert(!asmUtil.utf8Validate(Buffer.from([0xF5, 0x80, 0x80, 0x80])), 'Leader byte F5 is invalid');
  assert(!asmUtil.utf8Validate(Buffer.from([0xFF])), 'Byte 0xFF is invalid');
  assert(!asmUtil.utf8Validate(Buffer.from([0xFE])), 'Byte 0xFE is invalid');

  // Invalid: truncated sequences
  assert(!asmUtil.utf8Validate(Buffer.from([0xC2])), 'Truncated 2-byte sequence is invalid');
  assert(!asmUtil.utf8Validate(Buffer.from([0xE0, 0xA0])), 'Truncated 3-byte sequence is invalid');
  assert(!asmUtil.utf8Validate(Buffer.from([0xF0, 0x90, 0x80])), 'Truncated 4-byte sequence is invalid');
  assert(!asmUtil.utf8Validate(Buffer.from([0xF0, 0x90])), 'Truncated 4-byte (2 of 4) is invalid');

  // Invalid: continuation byte where leader expected
  assert(!asmUtil.utf8Validate(Buffer.from([0xC2, 0x00])), '2-byte with non-continuation (0x00) is invalid');
  assert(!asmUtil.utf8Validate(Buffer.from([0xC2, 0xC0])), '2-byte with non-continuation (0xC0) is invalid');
  assert(!asmUtil.utf8Validate(Buffer.from([0xE0, 0xA0, 0x00])), '3-byte with non-continuation is invalid');

  // Invalid embedded in valid: valid...invalid...valid
  assert(
    !asmUtil.utf8Validate(Buffer.from([0x41, 0x42, 0x80, 0x43])),
    'Bare continuation byte embedded in ASCII is invalid'
  );
  assert(
    !asmUtil.utf8Validate(Buffer.from([0x41, 0xED, 0xA0, 0x80, 0x43])),
    'Surrogate embedded in ASCII is invalid'
  );

  // Large valid ASCII buffer (exercises SIMD path)
  {
    const big = Buffer.alloc(1024, 'A');
    assert(asmUtil.utf8Validate(big), '1KB all-ASCII is valid (SIMD fast path)');
  }

  // Large valid ASCII with invalid byte at end (catches SIMD→scalar handoff)
  {
    const big = Buffer.alloc(1024, 'A');
    big[1023] = 0x80;
    assert(!asmUtil.utf8Validate(big), '1KB ASCII with trailing 0x80 is invalid');
  }

  // Large valid ASCII with valid multi-byte in the middle
  {
    const big = Buffer.alloc(1024, 'A');
    // Insert valid 3-byte UTF-8 (U+3053: E3 81 93)
    big[512] = 0xE3; big[513] = 0x81; big[514] = 0x93;
    assert(asmUtil.utf8Validate(big), '1KB ASCII with valid 3-byte in middle is valid');
  }

  // Large valid ASCII with truncated multi-byte at very end
  {
    const big = Buffer.alloc(1024, 'A');
    big[1023] = 0xC2;  // 2-byte leader with no continuation
    assert(!asmUtil.utf8Validate(big), '1KB ASCII with truncated 2-byte at end is invalid');
  }

  // Cross-reference with TextDecoder for random data
  {
    const decoder = new TextDecoder('utf-8', { fatal: true });
    let crossCheckPassed = 0;
    let crossCheckTotal = 200;
    for (let i = 0; i < crossCheckTotal; i++) {
      const size = 1 + Math.floor(Math.random() * 256);
      const buf = crypto.randomBytes(size);
      let expected;
      try {
        decoder.decode(buf);
        expected = true;
      } catch {
        expected = false;
      }
      const actual = asmUtil.utf8Validate(buf);
      if (actual === expected) crossCheckPassed++;
    }
    assert(
      crossCheckPassed === crossCheckTotal,
      `Cross-check vs TextDecoder: ${crossCheckPassed}/${crossCheckTotal} match`
    );
  }
}

// --- Test: sha1 function (if available) ---
if (typeof asmUtil.sha1 === 'function') {
  console.log('\nsha1() tests:');

  // FIPS 180-1 test vector #1: "abc"
  {
    const input = Buffer.from('abc');
    const expected = 'a9993e364706816aba3e25717850c26c9cd0d89d';
    const result = asmUtil.sha1(input).toString('hex');
    assert(result === expected, 'FIPS 180-1 vector: SHA1("abc")');
  }

  // FIPS 180-1 test vector #2: "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
  {
    const input = Buffer.from('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq');
    const expected = '84983e441c3bd26ebaae4aa1f95129e5e54670f1';
    const result = asmUtil.sha1(input).toString('hex');
    assert(result === expected, 'FIPS 180-1 vector: SHA1("abcdbcde...nopq") (56 bytes)');
  }

  // Empty input
  {
    const input = Buffer.alloc(0);
    const expected = crypto.createHash('sha1').update(input).digest('hex');
    const result = asmUtil.sha1(input).toString('hex');
    assert(result === expected, 'SHA1("") matches Node crypto');
  }

  // Single byte
  {
    const input = Buffer.from([0x42]);
    const expected = crypto.createHash('sha1').update(input).digest('hex');
    const result = asmUtil.sha1(input).toString('hex');
    assert(result === expected, 'SHA1(single byte 0x42) matches Node crypto');
  }

  // 20 bytes — typical SHA-1 digest size (WebSocket Sec-WebSocket-Accept input)
  {
    const input = crypto.randomBytes(20);
    const expected = crypto.createHash('sha1').update(input).digest('hex');
    const result = asmUtil.sha1(input).toString('hex');
    assert(result === expected, 'SHA1(20 random bytes) matches Node crypto');
  }

  // 55 bytes — last length that fits in one SHA-1 block (after padding)
  {
    const input = crypto.randomBytes(55);
    const expected = crypto.createHash('sha1').update(input).digest('hex');
    const result = asmUtil.sha1(input).toString('hex');
    assert(result === expected, 'SHA1(55 bytes) — single-block boundary');
  }

  // 56 bytes — first length requiring two SHA-1 blocks
  {
    const input = crypto.randomBytes(56);
    const expected = crypto.createHash('sha1').update(input).digest('hex');
    const result = asmUtil.sha1(input).toString('hex');
    assert(result === expected, 'SHA1(56 bytes) — two-block boundary');
  }

  // 60 bytes — typical Sec-WebSocket-Accept input size
  {
    const input = Buffer.from(
      'dGhlIHNhbXBsZSBub25jZTI1ODhFQUZBNS1FOTE0LTQ3REEtOTVDQS1DNUFCMERDODUxMQ=='
    );
    const expected = crypto.createHash('sha1').update(input).digest('hex');
    const result = asmUtil.sha1(input).toString('hex');
    assert(result === expected, 'SHA1(base64 WebSocket key, ~60 bytes) matches Node crypto');
  }

  // 119 bytes — maximum documented for 2-block SHA-1
  {
    const input = crypto.randomBytes(119);
    const expected = crypto.createHash('sha1').update(input).digest('hex');
    const result = asmUtil.sha1(input).toString('hex');
    assert(result === expected, 'SHA1(119 bytes) — max two-block input');
  }

  // Output is always 20 bytes
  {
    const result = asmUtil.sha1(Buffer.from('test'));
    assert(result.length === 20, 'SHA1 output is exactly 20 bytes');
  }

  // Cross-check: 50 random inputs of varying sizes (1–119 bytes)
  {
    let crossPassed = 0;
    const total = 50;
    for (let i = 0; i < total; i++) {
      const size = 1 + Math.floor(Math.random() * 119);
      const input = crypto.randomBytes(size);
      const expected = crypto.createHash('sha1').update(input).digest('hex');
      const result = asmUtil.sha1(input).toString('hex');
      if (result === expected) crossPassed++;
    }
    assert(crossPassed === total, `SHA1 cross-check vs Node crypto: ${crossPassed}/${total} match`);
  }
}

// --- Test: findHeader function (if available) ---
if (typeof asmUtil.findHeader === 'function') {
  console.log('\nfindHeader() tests:');

  // Basic: needle at end of buffer (returns position AFTER match)
  {
    const buf = Buffer.from('HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n');
    const needle = Buffer.from('\r\n\r\n');
    const result = asmUtil.findHeader(buf, needle);
    const expected = buf.indexOf(needle) + needle.length;
    assert(result === expected, 'Finds \\r\\n\\r\\n in HTTP response header');
  }

  // Needle at the very start (position 0)
  {
    const needle = Buffer.from('HEAD');
    const buf = Buffer.from('HEADER: value\r\n');
    const result = asmUtil.findHeader(buf, needle);
    assert(result === needle.length, 'Needle at position 0');
  }

  // Needle at the very end
  {
    const needle = Buffer.from('END');
    const buf = Buffer.from('START MIDDLE END');
    const result = asmUtil.findHeader(buf, needle);
    assert(result === buf.length, 'Needle at end of buffer');
  }

  // Needle not found — returns -1
  {
    const buf = Buffer.from('Hello World');
    const needle = Buffer.from('XYZ');
    const result = asmUtil.findHeader(buf, needle);
    assert(result === -1, 'Returns -1 when needle not found');
  }

  // Empty needle — returns -1
  {
    const buf = Buffer.from('Hello');
    const needle = Buffer.alloc(0);
    const result = asmUtil.findHeader(buf, needle);
    assert(result === -1, 'Empty needle returns -1');
  }

  // Needle longer than haystack — returns -1
  {
    const buf = Buffer.from('Hi');
    const needle = Buffer.from('Hello World');
    const result = asmUtil.findHeader(buf, needle);
    assert(result === -1, 'Needle longer than haystack returns -1');
  }

  // Single-byte needle
  {
    const buf = Buffer.from('ABCDEF');
    const needle = Buffer.from('D');
    const result = asmUtil.findHeader(buf, needle);
    assert(result === 4, 'Single-byte needle found at correct position');
  }

  // Multiple occurrences — should find the first
  {
    const buf = Buffer.from('ABCABC');
    const needle = Buffer.from('BC');
    const result = asmUtil.findHeader(buf, needle);
    // First occurrence at index 1, return 1 + 2 = 3
    assert(result === 3, 'Returns first occurrence (not last)');
  }

  // Exact match — buffer equals needle
  {
    const needle = Buffer.from('exact');
    const buf = Buffer.from('exact');
    const result = asmUtil.findHeader(buf, needle);
    assert(result === 5, 'Exact match: buffer equals needle');
  }

  // Large buffer — exercises SIMD path (needle near end)
  {
    const size = 4096;
    const buf = Buffer.alloc(size, 0x41); // fill with 'A'
    const needle = Buffer.from('\r\n\r\n');
    buf[size - 4] = 0x0d;
    buf[size - 3] = 0x0a;
    buf[size - 2] = 0x0d;
    buf[size - 1] = 0x0a;
    const result = asmUtil.findHeader(buf, needle);
    assert(result === size, '4KB buffer: needle at end (SIMD path)');
  }

  // Large buffer — needle near start
  {
    const size = 4096;
    const buf = Buffer.alloc(size, 0x41);
    const needle = Buffer.from('\r\n\r\n');
    buf[4] = 0x0d;
    buf[5] = 0x0a;
    buf[6] = 0x0d;
    buf[7] = 0x0a;
    const result = asmUtil.findHeader(buf, needle);
    assert(result === 8, '4KB buffer: needle near start');
  }

  // Large buffer — needle not present
  {
    const buf = Buffer.alloc(4096, 0x41);
    const needle = Buffer.from('\r\n\r\n');
    const result = asmUtil.findHeader(buf, needle);
    assert(result === -1, '4KB buffer: needle absent returns -1');
  }

  // Partial match — needle prefix present but full needle absent
  {
    const buf = Buffer.from('ABC\r\nDEF\r\nGHI');
    const needle = Buffer.from('\r\n\r\n');
    const result = asmUtil.findHeader(buf, needle);
    assert(result === -1, 'Partial match (\\r\\n but not \\r\\n\\r\\n) returns -1');
  }

  // Cross-check with Buffer.indexOf for random data
  {
    let crossPassed = 0;
    const total = 100;
    for (let i = 0; i < total; i++) {
      const size = 64 + Math.floor(Math.random() * 4000);
      const buf = crypto.randomBytes(size);
      const needle = Buffer.from('\r\n\r\n');
      // Randomly plant the needle ~50% of the time
      if (Math.random() < 0.5) {
        const pos = Math.floor(Math.random() * (size - 4));
        buf[pos] = 0x0d;
        buf[pos + 1] = 0x0a;
        buf[pos + 2] = 0x0d;
        buf[pos + 3] = 0x0a;
      }
      const jsIdx = buf.indexOf(needle);
      const expected = jsIdx === -1 ? -1 : jsIdx + needle.length;
      const result = asmUtil.findHeader(buf, needle);
      if (result === expected) crossPassed++;
    }
    assert(crossPassed === total, `findHeader cross-check vs indexOf: ${crossPassed}/${total} match`);
  }
}

// --- Test: mask/unmask alignment offsets ---
console.log('\nmask() alignment offset tests:');

{
  const testOffsets = [2, 4, 5, 7, 15, 31, 63];
  const source = crypto.randomBytes(256);
  const mask = crypto.randomBytes(4);

  for (const offset of testOffsets) {
    const output1 = Buffer.alloc(source.length + offset);
    const output2 = Buffer.alloc(source.length + offset);

    asmUtil.mask(source, mask, output1, offset, source.length);
    jsUtil.mask(source, mask, output2, offset, source.length);

    assert(
      buffersEqual(output1, output2),
      `mask with offset=${offset} (256-byte payload)`
    );
  }
}

// Alignment offsets with large (NT-path) payloads
{
  const testOffsets = [2, 4, 5, 7, 15, 31, 63];
  const source = crypto.randomBytes(512 * 1024);
  const mask = crypto.randomBytes(4);

  for (const offset of testOffsets) {
    const output1 = Buffer.alloc(source.length + offset);
    const output2 = Buffer.alloc(source.length + offset);

    asmUtil.mask(source, mask, output1, offset, source.length);
    jsUtil.mask(source, mask, output2, offset, source.length);

    assert(
      buffersEqual(output1, output2),
      `mask with offset=${offset} (512KB NT-path payload)`
    );
  }
}

// Unmask with misaligned buffers (subarray offsets)
console.log('\nunmask() alignment tests:');

{
  const testOffsets = [1, 2, 3, 5, 7, 15, 63];
  for (const off of testOffsets) {
    const backing = crypto.randomBytes(256 + off);
    const mask = crypto.randomBytes(4);
    const slice1 = Buffer.from(backing.subarray(off));
    const slice2 = Buffer.from(slice1);

    asmUtil.unmask(slice1, mask);
    jsUtil.unmask(slice2, mask);

    assert(
      buffersEqual(slice1, slice2),
      `unmask with buffer misaligned by ${off} bytes`
    );
  }
}

// --- Test: edge cases and bounds ---
console.log('\nEdge case / bounds tests:');

// mask: all payload sizes 0–66 (covers scalar, SSE boundary, AVX transition)
{
  let allMatch = true;
  for (let size = 0; size <= 66; size++) {
    const source = crypto.randomBytes(size);
    const mask = crypto.randomBytes(4);
    const out1 = Buffer.alloc(size);
    const out2 = Buffer.alloc(size);

    asmUtil.mask(source, mask, out1, 0, size);
    jsUtil.mask(source, mask, out2, 0, size);

    if (!buffersEqual(out1, out2)) {
      allMatch = false;
      console.error(`    FAIL at size=${size}`);
    }
  }
  assert(allMatch, 'mask correctness for every size 0–66');
}

// unmask: all payload sizes 0–66
{
  let allMatch = true;
  for (let size = 0; size <= 66; size++) {
    const mask = crypto.randomBytes(4);
    const buf1 = crypto.randomBytes(size);
    const buf2 = Buffer.from(buf1);

    asmUtil.unmask(buf1, mask);
    jsUtil.unmask(buf2, mask);

    if (!buffersEqual(buf1, buf2)) {
      allMatch = false;
      console.error(`    FAIL at size=${size}`);
    }
  }
  assert(allMatch, 'unmask correctness for every size 0–66');
}

// NT-store threshold boundary: test sizes just around 256KB
{
  const threshold = 256 * 1024;
  const testSizes = [threshold - 1, threshold, threshold + 1, threshold + 64];
  for (const size of testSizes) {
    const source = crypto.randomBytes(size);
    const mask = crypto.randomBytes(4);
    const out1 = Buffer.alloc(size);
    const out2 = Buffer.alloc(size);

    asmUtil.mask(source, mask, out1, 0, size);
    jsUtil.mask(source, mask, out2, 0, size);

    assert(
      buffersEqual(out1, out2),
      `mask at NT threshold boundary (${size} bytes)`
    );
  }
}

// All mask bytes = 0x00 (XOR is identity — output should equal source)
{
  const source = crypto.randomBytes(200);
  const mask = Buffer.from([0x00, 0x00, 0x00, 0x00]);
  const output = Buffer.alloc(200);

  asmUtil.mask(source, mask, output, 0, source.length);
  assert(buffersEqual(output, source), 'mask with all-zero mask is identity');
}

// All mask bytes = 0xFF (double-apply recovers original)
{
  const original = crypto.randomBytes(200);
  const mask = Buffer.from([0xFF, 0xFF, 0xFF, 0xFF]);
  const buf = Buffer.from(original);

  asmUtil.unmask(buf, mask);
  asmUtil.unmask(buf, mask);

  assert(buffersEqual(buf, original), 'unmask with 0xFF mask twice recovers original');
}

// base64Encode edge cases
if (typeof asmUtil.base64Encode === 'function') {
  console.log('\nbase64Encode() edge case tests:');

  // Single byte
  {
    const result = asmUtil.base64Encode(Buffer.from([0x00])).toString('ascii');
    assert(result === 'AA==', 'base64(0x00) = "AA=="');
  }

  // Two bytes
  {
    const result = asmUtil.base64Encode(Buffer.from([0xFF, 0xFF])).toString('ascii');
    assert(result === '//8=', 'base64(0xFF 0xFF) = "//8="');
  }

  // Output length is always ceil(n/3)*4
  {
    let allCorrect = true;
    for (let n = 0; n <= 48; n++) {
      const input = crypto.randomBytes(n);
      const result = asmUtil.base64Encode(input);
      const expected = Math.ceil(n / 3) * 4;
      if (result.length !== expected) {
        allCorrect = false;
        console.error(`    FAIL: base64Encode(${n} bytes).length = ${result.length}, expected ${expected}`);
      }
    }
    assert(allCorrect, 'base64 output length = ceil(n/3)*4 for sizes 0–48');
  }
}

// utf8Validate: SIMD→scalar boundary transitions
if (typeof asmUtil.utf8Validate === 'function') {
  console.log('\nutf8Validate() SIMD boundary tests:');

  // Invalid byte right at SIMD chunk boundaries (16, 32, 64 byte boundaries)
  {
    const boundaries = [15, 16, 17, 31, 32, 33, 63, 64, 65];
    for (const pos of boundaries) {
      const buf = Buffer.alloc(pos + 1, 0x41);  // fill with ASCII 'A'
      buf[pos] = 0x80;  // invalid bare continuation byte
      assert(
        !asmUtil.utf8Validate(buf),
        `Invalid byte at position ${pos} (SIMD boundary) detected`
      );
    }
  }

  // Valid multi-byte sequence spanning a SIMD chunk boundary
  {
    // 3-byte sequence starting at byte 62 spans into the next 64-byte chunk
    const buf = Buffer.alloc(128, 0x41);
    buf[62] = 0xE3; buf[63] = 0x81; buf[64] = 0x93;  // U+3053 (こ)
    assert(
      asmUtil.utf8Validate(buf),
      'Valid 3-byte sequence spanning 64-byte SIMD boundary'
    );
  }

  // Valid 4-byte at chunk boundary
  {
    const buf = Buffer.alloc(128, 0x41);
    buf[61] = 0xF0; buf[62] = 0x9F; buf[63] = 0x98; buf[64] = 0x80; // U+1F600
    assert(
      asmUtil.utf8Validate(buf),
      'Valid 4-byte sequence spanning 64-byte SIMD boundary'
    );
  }
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
    if (asmUtil.cpuFeatures & 64) bits.push('VBMI2');
    console.log(`  (detected: 0x${asmUtil.cpuFeatures.toString(16).padStart(2,'0')} = [${bits.join(', ') || 'none'}])`);
  }
}

console.log(`\nResults: ${passed} passed, ${failed} failed\n`);
process.exit(failed > 0 ? 1 : 0);
