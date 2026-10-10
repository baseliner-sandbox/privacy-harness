#!/usr/bin/env bash
# What a token reports and does when it opens a labelled issue (#133).
#   label_probe.sh REPO
# Uses GH_TOKEN. Prints the token's permissions on REPO as GitHub reports
# them, opens an issue with the label "baseliner-probe", prints the labels
# the created issue got, and closes it. REPO must be public: this log is.
set -euo pipefail

repo=${1:?repo}
echo "permissions reported for $repo: $(gh api "repos/$repo" -q '.permissions // "none"' 2>&1)"
gh api "repos/$repo/labels/baseliner-probe" >/dev/null 2>&1 ||
	gh api "repos/$repo/labels" -f name=baseliner-probe -f color=cccccc >/dev/null 2>&1 ||
	echo "could not ensure the label (the create below shows the effect)"
number=$(gh api "repos/$repo/issues" -f title="label probe" -f body="Opened by the label probe; closed at once." -f 'labels[]=baseliner-probe' -q .number)
labels=$(gh api "repos/$repo/issues/$number" -q '[.labels[].name]|join(",")')
echo "issue #$number created with labels: [${labels}]"
gh api -X PATCH "repos/$repo/issues/$number" -f state=closed >/dev/null
if [ "$labels" = baseliner-probe ]; then
	echo "RESULT: label kept"
else
	echo "RESULT: label dropped"
fi
