# Benchmark Workflow Design

**Date:** 2026-04-13  
**Status:** Approved

## Overview

Add a dedicated GitHub Actions workflow (`benchmark.yml`) that runs the existing `npm run bench` benchmark on every push to `master` and every pull request targeting `master`. Results are stored as a downloadable artifact and posted as a sticky comment on pull requests for visibility during code review.

## Trigger & Environment

- **File:** `.github/workflows/benchmark.yml`
- **Triggers:**
  - `push` → `master`
  - `pull_request` → `master`
- **Runner:** `ubuntu-latest`
- **Node version:** 22
- **Not a required status check** — benchmark failures do not block merges

A single non-matrix environment is intentional: benchmarks require a consistent, reproducible environment to produce comparable numbers. Linux is the only platform where the native addon builds reliably.

## Job Steps

Job name: `benchmark`

1. **Checkout** — `actions/checkout@v4`
2. **Setup Node** — `actions/setup-node@v4`, node-version: 22
3. **Install NASM** — `sudo apt-get install -y nasm` (required for native addon assembly)
4. **Install deps** — `npm install --ignore-scripts`
5. **Build native addon** — `npm run build` (fails job if build fails; no point posting meaningless results)
6. **Run benchmark** — `npm run bench 2>&1 | tee bench-output.txt` (captures both stdout and stderr)
7. **Upload artifact** — `actions/upload-artifact@v4`, name: `benchmark-results`, path: `bench-output.txt`, retention: 30 days
8. **Post PR comment** — `marocchino/sticky-pull-request-comment@v2`, conditional on `github.event_name == 'pull_request'`; reads `bench-output.txt`, wraps in a fenced `text` code block under a `## Benchmark Results` heading; uses built-in `GITHUB_TOKEN` (no additional secrets required); edits the same comment on subsequent pushes to the same PR rather than posting new ones

## PR Comment Format

```markdown
## Benchmark Results (Linux x64, Node 22)

\`\`\`text
[bench-output.txt contents]
\`\`\`
```

## Dependencies

- `marocchino/sticky-pull-request-comment@v2` — third-party action, pinned to `v2`
- `GITHUB_TOKEN` — built-in, no configuration needed

## What Is Not In Scope

- Performance regression gating (no baseline comparison, no threshold checks)
- Cross-platform benchmark runs (Windows/macOS native builds are unreliable)
- Multiple Node version matrix for benchmarks
- Modifications to `bench/index.js`
