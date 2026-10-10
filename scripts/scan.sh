#!/usr/bin/env bash
# Run one privacy case of baseliner.
#   scan.sh CASE BINARY
# CASE is MODE, gitlab-MODE or forgejo-MODE, where MODE is one of:
#   default  no privacy settings: under GitHub Actions the guard is on (redact)
#   redact   public context, private repos masked
#   exclude  public context, private repos left out
#   issues   default settings, real --open-issues (GitHub only)
#   off      guard off: proves the check can see a leak. Output goes to files
#            only, never to this public log, and is checked in the job.
# A plain MODE scans this GitHub org; gitlab-MODE the gitlab.com group in
# GITLAB_GROUP (token GITLAB_TOKEN); forgejo-MODE the throwaway Forgejo
# started by forgejo_fixtures.sh, both of its organisations.
# Outputs land in out/CASE. Exits non-zero only when baseliner errors (exit
# 2 or more); failing checks (exit 1) are expected.
set -euo pipefail

case_=${1:?case}
bin=${2:?binary}
forge=github
mode=$case_
case "$case_" in
gitlab-*) forge=gitlab mode=${case_#gitlab-} ;;
forgejo-*) forge=forgejo mode=${case_#forgejo-} ;;
esac

# scan writes a config for SCOPE (YAML lines under scope:) into DIR and runs
# baseliner there.
scan() {
	local dir=$1 scope=$2
	mkdir -p "$dir"
	{
		echo "scope:"
		printf '%s\n' "$scope"
		echo "policy:"
		echo "  base: default"
		echo "  repo_waivers:"
		echo "    allow: [license_exists]"
		case "$mode" in
		default | issues) ;;
		redact | exclude) printf 'privacy:\n  public_context: true\n  private_repos: %s\n' "$mode" ;;
		off) printf 'privacy:\n  public_context: false\n' ;;
		*)
			echo "unknown mode: $mode" >&2
			exit 64
			;;
		esac
	} >"$dir/baseliner.yaml"

	local args=(scan --config "$dir/baseliner.yaml" --format both --verbose
		--output-file "$dir/results.json" --sarif-file "$dir/results.sarif" --markdown-file "$dir/report.md"
		--fail-under 0.99 --min-coverage 1)
	# Findings issues are GitHub only: real ones in the issues case, a dry run
	# in the others, which still exercises the issue lookups.
	if [ "$forge" = github ]; then
		args+=(--open-issues)
		if [ "$mode" != issues ]; then
			args+=(--dry-run)
		fi
	fi

	local code
	set +e
	if [ "$mode" = off ]; then
		"$bin" "${args[@]}" >"$dir/stdout.txt" 2>"$dir/stderr.txt"
		code=$?
	else
		"$bin" "${args[@]}" 2>&1 | tee "$dir/log.txt"
		code=${PIPESTATUS[0]}
	fi
	set -e
	echo "baseliner exit code: $code"
	if [ "$code" -ge 2 ]; then
		echo "::error::baseliner exited $code in case $case_"
		exit 1
	fi
}

out="out/$case_"
case "$forge" in
github)
	scan "$out" $'  github:\n    type: org\n    name: baseliner-sandbox\n    include_archived: true'
	;;
gitlab)
	scan "$out" "$(printf '  gitlab:\n    group: %s\n    include_archived: true' "${GITLAB_GROUP:-baseliner-sandbox}")"
	;;
forgejo)
	GITEA_TOKEN=$(cat "$RUNNER_TEMP/forgejo.token")
	export GITEA_TOKEN
	for org in fx fxl; do
		scan "$out/$org" "$(printf '  gitea:\n    type: org\n    name: %s\n    base_url: http://127.0.0.1:3000\n    include_archived: true' "$org")"
	done
	;;
esac
