# Follow-ups

Open issues / deferred TODOs noted during PR reviews. Each entry includes observable symptom, location in code, why it matters, and a concrete next step.

---

### 1. Legacy tests reference removed `deploy/partner-edge/` path

**Where:** `tests/test_sfu_compose.sh`, `tests/test_install_ships_cover.sh`, `tests/test_install_wires_cert_watch.sh` (and possibly siblings) hardcode `REPO_ROOT=$(...)/deploy/partner-edge/` or similar legacy sub-path that no longer exists in this repo layout.

**Symptom:** scripts exit immediately or read non-existent fixtures. Effectively dead tests.

**Why it matters:** false sense of coverage. CI / shellcheck won't catch it because the scripts are not wired into automation; manual smoke runs would, but they're noted as broken in PR #49 and skipped.

**Next step:** audit `tests/test_*.sh`. For each: either update `REPO_ROOT` to repo root + adjust path prefixes (matching PR #49's `tests/test_install_die_on_empty_sfu_secret.sh` pattern), or delete the test if its target was removed in a prior layout change. ~30 min of grep + path fixes.

**Files:** `tests/test_*.sh` — count via `ls tests/test_*.sh | wc -l`.

**Discovered:** PR #49 review (2026-05-06).

---

## How to use this file
- Adding an entry: append below. Include observable symptom, where in code, why it matters, and a concrete next step.
- Closing an entry: ~~strikethrough the title and body~~ with `(closed YYYY-MM-DD via SHA)` appended. Keep the entry — history matters.

---

### 2. update.sh template fetch missing `--retry` (review of #113)

`update.sh:157` — template curl from `REPO_RAW` has `--max-time 30` but no `--retry`. API curl got `--retry 3 --retry-delay 2 --retry-connrefused` in the same amendment; template curl was missed. Transient CDN timeout = single-shot `die`. Russian partner nodes (Hetzner/Cloudflare path) — high failure probability.

**Fix:** add `--retry 3 --retry-delay 2 --retry-connrefused` to template curl. Same flag set as API curl.

### 3. Missing test scenarios (review of #113)

Tests T7/T8/T9 cover docker restart failure, missing compose file, curl `--retry` flag presence. Prior reviewer's explicit asks not yet covered:
- **Malformed API JSON**: API returns `{"error": "..."}` (valid JSON, no `node_id`). Current code dies via `die "reality_uuid missing"` — needs explicit test.
- **SIGTERM mid-render**: verify `xray-client.json` is not left zero-length after Ctrl+C between download and install. Current trap chain is probably safe; add test to prove.

### 4. `install -m 0600` on log file failure mode

`update.sh:47` — `install -m 0600 /dev/null "$LOG_FILE" 2>/dev/null || true` silently swallows error if log directory doesn't exist. Script then fails later at first `tee -a` with cryptic write error. Either pre-create directory or die clearly.
