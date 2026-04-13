# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

## [0.1.0] - 2026-04-13

### Added
- `mask(source, mask, output, offset, length)` — WebSocket frame masking with SSE2/NT-store SIMD dispatch
- `unmask(buffer, mask)` — In-place WebSocket frame unmasking with SSE2/NT-store SIMD dispatch
- `base64Encode(input)` — Base64 encoding with AVX2/GFNI/SSE2/scalar CPU dispatch
- `crc32(buffer, init)` — CRC32 using SSE4.2 `CRC32` instruction
- `sha1(data)` — SHA-1 using Intel SHA-NI hardware instructions
- `cpuFeatures` — Bitmask exposing detected CPU capabilities (SSE2, AVX2, BMI2, GFNI, SHA-NI, SSE4.2)
- BMI2 runtime dispatch for WebSocket frame parsing (PEXT/LZCNT/RORX)
- N-API ABI-stable interface — works across Node.js versions without recompile
- Pure JavaScript fallback for non-Linux or non-x64 platforms
