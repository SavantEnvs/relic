#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the upstream RELIC functional test suite (built by mayhem/build.sh into
# build-tests/bin/test_*). Behavioral oracle: a module PASSES only if it prints RELIC's own
# "All tests have passed." banner. A module that cannot run under the generic default configuration
# (RELIC prints "no curve/group supported at this security level" and still exit(0)s) is SKIPPED
# with that reason — NOT counted as passed. Anything else (a real [FAIL], a FATAL/ERROR, a nonzero
# exit, or NO banner at all — e.g. a sabotaged exit(0) binary) is a FAILURE. Emits CTRF.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

BIN="$SRC/build-tests/bin"
if [ ! -d "$BIN" ] || ! ls "$BIN"/test_* >/dev/null 2>&1; then
  echo "test runner missing ($BIN/test_*) — mayhem/build.sh did not build the suite" >&2
  emit_ctrf "relic-testsuite" 0 1
  exit 1
fi

passed=0; failed=0; skipped=0
for t in "$BIN"/test_*; do
  [ -x "$t" ] || continue
  name="$(basename "$t")"
  out="$("$t" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "All tests have passed."; then
    passed=$((passed+1))
  elif [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qiE "no (curve|group|prime|extension|pairing).*supported|not supported at this security level"; then
    skipped=$((skipped+1)); echo "SKIP $name: unsupported under the generic default configuration"
  else
    failed=$((failed+1)); echo "FAIL $name (rc=$rc):"
    printf '%s\n' "$out" | grep -iE "\[FAIL\]|FATAL|ERROR" | head -3
  fi
done

emit_ctrf "relic-testsuite" "$passed" "$failed" "$skipped"
