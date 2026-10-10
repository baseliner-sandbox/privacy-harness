#!/usr/bin/env python3
"""Create the private fixture repos on GitLab or Codeberg, once.

    fixtures.py gitlab     uses GITLAB_SETUP_TOKEN (scope api)
    fixtures.py codeberg   uses CODEBERG_SETUP_TOKEN (write:organization, write:repository)

Names are random and never printed: the harness finds the fixtures through
the API and checks them by what they are. Running it again when the fixtures
exist does nothing.
"""

import base64
import json
import os
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request

GITLAB_GROUP = os.environ.get("GITLAB_GROUP") or "baseliner-sandbox"
CODEBERG_ORG = os.environ.get("CODEBERG_ORG") or "baseliner-sandbox"
WAIVER = "version: 1\nwaivers:\n  - check: license_exists\n    reason: CANARY-REASON internal detail\n"


def rand():
    return "fx-" + secrets.token_hex(4)


class API:
    def __init__(self, base, token, auth):
        self.base, self.headers = base, {auth[0]: auth[1].format(token), "Content-Type": "application/json"}

    def call(self, method, path, body=None):
        req = urllib.request.Request(self.base + path, method=method, headers=self.headers,
                                     data=json.dumps(body).encode() if body is not None else None)
        try:
            with urllib.request.urlopen(req) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            # Never print a URL or body: they would name a fixture.
            sys.exit(f"{method} failed: HTTP {e.code}")


def gitlab():
    token = os.environ.get("GITLAB_SETUP_TOKEN") or sys.exit("GITLAB_SETUP_TOKEN is not set")
    api = API("https://gitlab.com/api/v4", token, ("PRIVATE-TOKEN", "{}"))
    group = api.call("GET", "/groups/" + urllib.parse.quote(GITLAB_GROUP, safe=""))
    projects = api.call("GET", f"/groups/{group['id']}/projects?include_subgroups=true&per_page=100")
    if sum(p["visibility"] == "private" for p in projects) >= 5:
        print("GitLab fixtures already exist; nothing to do")
        return

    def project(name, visibility, namespace):
        return api.call("POST", "/projects", {"name": name, "path": name, "namespace_id": namespace,
                                              "visibility": visibility, "initialize_with_readme": True})

    project(rand(), "private", group["id"])  # fails most checks
    w = project(rand(), "private", group["id"])  # waiver with the canary marker
    api.call("POST", f"/projects/{w['id']}/repository/files/.baseliner.yml",
             {"branch": w["default_branch"] or "main", "content": WAIVER, "commit_message": "add waiver fixture"})
    a = project(rand(), "private", group["id"])  # archived
    api.call("POST", f"/projects/{a['id']}/archive")
    sub = api.call("POST", "/groups", {"name": rand(), "path": rand(), "parent_id": group["id"], "visibility": "private"})
    project(rand(), "private", sub["id"])  # nested: group/sub/project
    prefix = rand()
    project(prefix + "-kit", "public", group["id"])  # a public name ...
    project(prefix, "private", group["id"])  # ... that a private one prefixes
    print("GitLab fixtures created: 5 private projects (one archived, one nested, one with a waiver), 1 public")


def codeberg():
    token = os.environ.get("CODEBERG_SETUP_TOKEN") or sys.exit("CODEBERG_SETUP_TOKEN is not set")
    api = API("https://codeberg.org/api/v1", token, ("Authorization", "token {}"))
    repos = api.call("GET", f"/orgs/{CODEBERG_ORG}/repos?limit=50")
    if sum(r["private"] for r in repos) >= 4:
        print("Codeberg fixtures already exist; nothing to do")
        return

    def repo(name, private):
        return api.call("POST", f"/orgs/{CODEBERG_ORG}/repos", {"name": name, "private": private, "auto_init": True,
                                                       "readme": "Default"})

    repo(rand(), True)
    w = repo(rand(), True)
    api.call("POST", f"/repos/{CODEBERG_ORG}/{w['name']}/contents/.baseliner.yml",
             {"content": base64.b64encode(WAIVER.encode()).decode(), "message": "add waiver fixture"})
    a = repo(rand(), True)
    api.call("PATCH", f"/repos/{CODEBERG_ORG}/{a['name']}", {"archived": True})
    prefix = rand()
    repo(prefix + "-kit", False)
    repo(prefix, True)
    print("Codeberg fixtures created: 4 private repos (one archived, one with a waiver), 1 public")


if __name__ == "__main__":
    {"gitlab": gitlab, "codeberg": codeberg}.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: sys.exit(__doc__))()
