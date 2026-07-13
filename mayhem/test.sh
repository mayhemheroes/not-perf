#!/usr/bin/env bash
#
# mayhem/test.sh — RUN not-perf's OWN upstream test suite (already compiled by mayhem/build.sh
# via `cargo test --no-run`). This is upstream's full cargo test suite (per ci/run_tests.sh):
# every buildable workspace crate (nwind, proc-maps, perf_event_open, thread-local-reentrant,
# cli) plus nwind's feature-gated `local-unwinding` tests. The suite asserts BEHAVIOR
# (assert_eq!/quickcheck properties on archive decoding, DWARF/CFI unwinding, range maps,
# /proc parsing), so a PATCH that neuters the program to exit(0) FAILS here. Emits CTRF.
#
# Skipped vs upstream CI (ci/run_tests.sh):
#  * the root nperf-core package's tests — they do NOT compile at upstream tip (upstream
#    bug: src/data_reader.rs test mod misses the `jitdump_path` field and the
#    `FrameKind::UserByFunctionJit` match arm; edits must stay additive so we can't fix it);
#  * nwind's 7 `local_unwinding::*` live self-unwind tests — they fail at upstream tip in
#    containerized environments (`assertion failed: !duplicate_matches`,
#    nwind/src/address_space.rs:929, tripped by the modern /proc/self/maps layout while
#    unwinding the live test process — not something this port introduced);
#  * the `--release`-mode re-run of the same nwind tests (duplicate test bodies);
#  * the cross-target `cargo check` invocations (type checks, not tests).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# RUN the suite build.sh already compiled. RUSTFLAGS is left unset (the fuzz flags are
# build-only), so this is the project's normal build — a near-no-op recompile, then the
# tests run (nwind's local-unwinding .s stubs need gas, hence CC=gcc). RUST_BACKTRACE matches upstream's ci/run_tests.sh.
export RUST_BACKTRACE=1
LOG="$(mktemp)"
rc=0
env -u RUSTFLAGS cargo test --workspace --exclude nperf-core --no-fail-fast 2>&1 | tee -a "$LOG" || rc=$?
( cd nwind && env -u RUSTFLAGS CC=gcc cargo test --features local-unwinding --no-fail-fast -- --skip local_unwinding:: ) 2>&1 | tee -a "$LOG" || rc=$?

# Aggregate every libtest "test result: ..." summary line (unit + integration + doctests).
read -r passed failed skipped < <(awk '
  /^test result:/ {
    for (i = 1; i <= NF; i++) {
      if ($(i+1) == "passed;")  p += $i
      if ($(i+1) == "failed;")  f += $i
      if ($(i+1) == "ignored;") s += $i
    }
  }
  END { printf "%d %d %d\n", p, f, s }
' "$LOG")
rm -f "$LOG"

# A cargo/compile failure (rc!=0) with no parsed tests must FAIL loudly — the runner should
# have been built by build.sh.
if [ "$rc" -ne 0 ] && [ "$((passed + failed))" -eq 0 ]; then
  echo "ERROR: cargo test produced no results (rc=$rc) — build.sh should have compiled the suite" >&2
  emit_ctrf "cargo-test" 0 1 0
  exit 1
fi

emit_ctrf "cargo-test" "$passed" "$failed" "$skipped"
