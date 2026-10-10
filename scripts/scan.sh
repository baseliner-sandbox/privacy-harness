#!/usr/bin/env bash
# Run one privacy case of baseliner against the baseliner-sandbox org.
#   scan.sh CASE BINARY
# CASE is one of:
#   default  no privacy settings: under GitHub Actions the guard is on (redact)
#   redact   public context, private repos masked
#   exclude  public context, private repos left out
#   issues   default settings, real --open-issues on every repo in the org
#   off      guard off: proves the check can see a leak. Output goes to files
#            only, never to this public log, and is checked in the job.
# Outputs land in out/CASE. Exits non-zero only when baseliner errors (exit
# 2 or more); failing checks (exit 1) are expected.
set -euo pipefail

case_=${1:?case}
bin=${2:?binary}
out="out/$case_"
mkdir -p "$out"
cfg="$out/baseliner.yaml"

{
	echo "scope:"
	echo "  github:"
	echo "    type: org"
	echo "    name: baseliner-sandbox"
	echo "    include_archived: true"
	echo "policy:"
	echo "  base: default"
	echo "  repo_waivers:"
	echo "    allow: [license_exists]"
	case "$case_" in
	default | issues) ;;
	redact | exclude) printf 'privacy:\n  public_context: true\n  private_repos: %s\n' "$case_" ;;
	off) printf 'privacy:\n  public_context: false\n' ;;
	*)
		echo "unknown case: $case_" >&2
		exit 64
		;;
	esac
} >"$cfg"

args=(scan --config "$cfg" --format both --verbose
	--output-file "$out/results.json" --sarif-file "$out/results.sarif" --markdown-file "$out/report.md"
	--fail-under 0.99 --min-coverage 1 --open-issues)
if [ "$case_" != issues ]; then
	args+=(--dry-run)
fi

set +e
if [ "$case_" = off ]; then
	"$bin" "${args[@]}" >"$out/stdout.txt" 2>"$out/stderr.txt"
	code=$?
else
	"$bin" "${args[@]}" 2>&1 | tee "$out/log.txt"
	code=${PIPESTATUS[0]}
fi
set -e
echo "baseliner exit code: $code"
if [ "$code" -ge 2 ]; then
	echo "::error::baseliner exited $code in case $case_"
	exit 1
fi
