#!/usr/bin/env bash
# Start a throwaway Forgejo and create its fixtures, for the forgejo-* cases.
#   forgejo_fixtures.sh
# Writes a scan token to $RUNNER_TEMP/forgejo.token (masked in the log). The
# instance lives only for this job, so its fixture names (FORGEJO_PRIVATE in
# check.py) are not secret; the check is that no public output names them.
#
#   org fx (public):  fx-open (public, with README, LICENSE, .forgejo/workflows/ci.yml)
#                     fx-hidden-alpha (private; waiver whose reason carries the canary)
#                     fx-hidden-archive (private, archived)
#   org fxl (limited): fx-hidden-limited (public by its own flags, but its
#                     organisation is visible to signed-in users only)
set -euo pipefail

image=codeberg.org/forgejo/forgejo:16
docker run -d --name forgejo -p 127.0.0.1:3000:3000 \
	-e FORGEJO__security__INSTALL_LOCK=true -e FORGEJO__database__DB_TYPE=sqlite3 \
	-e FORGEJO__server__ROOT_URL=http://127.0.0.1:3000/ "$image" >/dev/null
for _ in $(seq 1 60); do
	curl -sf http://127.0.0.1:3000/api/v1/version >/dev/null && break
	sleep 2
done
pw=$(openssl rand -hex 16)
echo "::add-mask::$pw"
docker exec -u git forgejo forgejo admin user create --admin --username fxadmin --password "$pw" \
	--email fx@example.invalid --must-change-password=false >/dev/null

B=http://127.0.0.1:3000/api/v1
admin=$(curl -sf -u "fxadmin:$pw" -X POST $B/users/fxadmin/tokens -H 'Content-Type: application/json' \
	-d '{"name":"setup","scopes":["all"]}' | jq -r .sha1)
echo "::add-mask::$admin"
api() { curl -sf -o /dev/null -H "Authorization: token $admin" -H 'Content-Type: application/json' "$@"; }

api -X POST $B/orgs -d '{"username":"fx","visibility":"public"}'
api -X POST $B/orgs -d '{"username":"fxl","visibility":"limited"}'
repo() { api -X POST "$B/orgs/$1/repos" -d "{\"name\":\"$2\",\"private\":$3,\"auto_init\":true,\"readme\":\"Default\"}"; }
file() { api -X POST "$B/repos/$1/contents/$2" -d "{\"content\":\"$(printf '%s' "$3" | base64 -w0)\",\"message\":\"add\"}"; }

repo fx fx-open false
file fx/fx-open LICENSE "MIT"
file fx/fx-open .forgejo/workflows/ci.yml "on: push"
repo fx fx-hidden-alpha true
file fx/fx-hidden-alpha .baseliner.yml $'waivers:\n  - check: license_exists\n    reason: CANARY-REASON forgejo detail\n'
repo fx fx-hidden-archive true
api -X PATCH $B/repos/fx/fx-hidden-archive -d '{"archived":true}'
repo fxl fx-hidden-limited false

scan=$(curl -sf -u "fxadmin:$pw" -X POST $B/users/fxadmin/tokens -H 'Content-Type: application/json' \
	-d '{"name":"scan","scopes":["read:organization","read:repository"]}' | jq -r .sha1)
echo "::add-mask::$scan"
printf '%s' "$scan" >"$RUNNER_TEMP/forgejo.token"
echo "Forgejo fixtures ready"
