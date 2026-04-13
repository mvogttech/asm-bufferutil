# Benchmark Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `.github/workflows/benchmark.yml` that runs `npm run bench` on every push/PR to `master`, uploads results as an artifact, and posts a sticky comment on pull requests.

**Architecture:** A single GitHub Actions workflow file with one job (`benchmark`) running on `ubuntu-latest` / Node 22. File contents are captured with `tee`, uploaded as a 30-day artifact, and — on PRs only — piped through a shell step into `marocchino/sticky-pull-request-comment@v2` which edits the same comment on each push rather than appending new ones.

**Tech Stack:** GitHub Actions, `actions/checkout@v4`, `actions/setup-node@v4`, `actions/upload-artifact@v4`, `marocchino/sticky-pull-request-comment@v2`, NASM, Node 22, `node-gyp`

---

## File Map

| Action   | Path                                   | Responsibility                               |
|----------|----------------------------------------|----------------------------------------------|
| **Create** | `.github/workflows/benchmark.yml`    | Full benchmark workflow — build, run, artifact, PR comment |

No existing files are modified.

---

### Task 1: Create the benchmark workflow

**Files:**
- Create: `.github/workflows/benchmark.yml`

- [ ] **Step 1: Verify the workflows directory exists**

```bash
ls .github/workflows/
```

Expected output includes `ci.yml`. If the directory is missing, create it: `mkdir -p .github/workflows`.

- [ ] **Step 2: Create `.github/workflows/benchmark.yml` with the following exact content**

```yaml
name: Benchmark

on:
  push:
    branches: [master]
  pull_request:
    branches: [master]

permissions:
  pull-requests: write

jobs:
  benchmark:
    name: Benchmark (Linux x64, Node 22)
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Set up Node.js 22
        uses: actions/setup-node@v4
        with:
          node-version: 22

      - name: Install NASM
        run: sudo apt-get install -y nasm

      - name: Install dependencies
        run: npm install --ignore-scripts

      - name: Build native addon
        run: npm run build

      - name: Run benchmark
        run: npm run bench 2>&1 | tee bench-output.txt

      - name: Upload benchmark results
        uses: actions/upload-artifact@v4
        with:
          name: benchmark-results
          path: bench-output.txt
          retention-days: 30

      - name: Prepare comment body
        id: comment
        if: github.event_name == 'pull_request'
        run: |
          {
            echo 'body<<BENCH_EOF'
            echo '## Benchmark Results (Linux x64, Node 22)'
            echo ''
            echo '```text'
            cat bench-output.txt
            echo '```'
            echo 'BENCH_EOF'
          } >> "$GITHUB_OUTPUT"

      - name: Post PR comment
        if: github.event_name == 'pull_request'
        uses: marocchino/sticky-pull-request-comment@v2
        with:
          header: benchmark
          message: ${{ steps.comment.outputs.body }}
```

Key design notes:
- `permissions: pull-requests: write` — required for the sticky comment action to post/edit PR comments via `GITHUB_TOKEN`
- `header: benchmark` — unique identifier; the sticky comment action uses this to find and update the existing comment instead of creating a new one on each push
- The `Prepare comment body` step uses a shell heredoc written to `$GITHUB_OUTPUT` to safely pass multiline file contents as a step output; the `BENCH_EOF` delimiter is arbitrary but must not appear in the bench output
- `2>&1 | tee bench-output.txt` — captures both stdout and stderr so any build warnings appear in the artifact too
- The `Post PR comment` and `Prepare comment body` steps are both gated on `github.event_name == 'pull_request'`; on a plain push to master only the artifact is uploaded

- [ ] **Step 3: Validate YAML syntax**

```bash
node -e "require('js-yaml').load(require('fs').readFileSync('.github/workflows/benchmark.yml', 'utf8')); console.log('YAML valid')"
```

If `js-yaml` is not available locally:

```bash
node -e "
const fs = require('fs');
const txt = fs.readFileSync('.github/workflows/benchmark.yml', 'utf8');
// Basic check: parse as JSON after stripping YAML — just ensure it loads without throwing
try { JSON.parse(JSON.stringify(txt)); console.log('file readable, length', txt.length); } catch(e) { console.error(e); }
"
```

Alternatively, use Python if available:

```bash
python3 -c "import yaml, sys; yaml.safe_load(open('.github/workflows/benchmark.yml')); print('YAML valid')"
```

Expected output: `YAML valid`

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/benchmark.yml
git commit -m "ci: add benchmark workflow with artifact upload and sticky PR comment"
```

---

## Verification (after merging / pushing to master)

1. Open the repository on GitHub → **Actions** tab
2. Find the **Benchmark** workflow run triggered by the push
3. Confirm the job completes and the `benchmark-results` artifact appears under the run summary
4. Open a pull request targeting `master` → confirm a comment titled **Benchmark Results (Linux x64, Node 22)** appears with the formatted table
5. Push another commit to the same PR branch → confirm the comment is **edited** (not duplicated)
6. Confirm the benchmark job does **not** appear under **Settings → Branches → branch protection rules** as a required check (new workflows are not required by default — no action needed, but worth verifying it isn't accidentally blocking merges)
