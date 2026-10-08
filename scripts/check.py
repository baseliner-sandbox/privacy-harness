#!/usr/bin/env python3
"""Check baseliner's output for private repo names.

    check.py present DIR    assert the guard-off output in DIR names every
                            private repo and the canary (proves the check
                            can see a leak); prints counts only
    check.py run            check this workflow run's scan job logs, its
                            artifacts and the sandbox's findings issues

The canaries are the sandbox's private repo names, read from the API with
SANDBOX_TOKEN at run time, and the waiver reason marker. They are never
printed: a finding names the output and the canary's index, never the name.
They are not stored as secrets either, since GitHub masks secret values in
logs and would hide the very leak this looks for.
"""

import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import urllib.request

ORG = "baseliner-sandbox"
FIXTURES = {"priv-fails", "priv-waiver", "priv-archived", "test-no"}
MARKER = "CANARY-REASON"
NAME = r"[A-Za-z0-9_.-]"


def private_names():
    """The sandbox's private repo names, from the API."""
    token = os.environ.get("SANDBOX_TOKEN", "")
    if not token:
        sys.exit("The SANDBOX_TOKEN secret is not set; see README.md")
    names, page = [], 1
    while True:
        req = urllib.request.Request(
            f"https://api.github.com/orgs/{ORG}/repos?type=private&per_page=100&page={page}",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"},
        )
        with urllib.request.urlopen(req) as resp:
            batch = json.load(resp)
        names += [r["name"] for r in batch if r.get("private")]
        if len(batch) < 100:
            return names
        page += 1


def canaries():
    names = private_names()
    missing = FIXTURES - set(names)
    if missing:
        # A fixture that disappeared would let the check pass on nothing.
        sys.exit(f"fixture drift: {len(missing)} expected private fixture(s) missing")
    # Each name as a whole name, so a public repo it prefixes (test-no-readme)
    # is not a hit; the marker as a plain substring.
    pats = [re.compile(rf"(?<!{NAME}){re.escape(n)}(?!{NAME})", re.I) for n in names]
    return pats + [re.compile(re.escape(MARKER), re.I)]


def hits(text, pats):
    return [i for i, p in enumerate(pats) if p.search(text)]


def present(directory):
    pats = canaries()
    text = "".join(p.read_text(errors="replace") for p in pathlib.Path(directory).rglob("*") if p.is_file())
    absent = [i for i, p in enumerate(pats) if not p.search(text)]
    print(f"guard off: {len(pats) - len(absent)} of {len(pats)} canaries present in the output")
    if absent:
        sys.exit(f"canaries {absent} absent with the guard off: the check could not see a leak")


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def run():
    pats = canaries()
    repo, run_id = os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_RUN_ID"]
    problems = []

    # 1. The scan jobs' logs: what a public reader of this run sees.
    jobs = json.loads(gh("api", f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=100"))["jobs"]
    scans = [j for j in jobs if j["name"].startswith("scan")]
    if not scans:
        sys.exit("no scan jobs found in this run")
    for j in scans:
        log = gh("api", f"repos/{repo}/actions/jobs/{j['id']}/logs")
        for i in hits(log, pats):
            problems.append(f"LEAK in the log of job '{j['name']}': canary #{i}")
        case = j["name"].split("(")[-1].rstrip(")").strip()
        if case in ("default", "redact", "issues") and "private/redacted" not in log:
            problems.append(f"job '{j['name']}' never masked a private repo: the case did not exercise the guard")
        if case == "exclude":
            if "private/redacted" in log or "private/1" in log:
                problems.append(f"job '{j['name']}' shows a masked private repo in exclude mode")
            if "private repo(s)" not in log:
                problems.append(f"job '{j['name']}' does not count the excluded private repos")
        print(f"checked log of '{j['name']}'")

    # 2. The run's artifacts.
    with tempfile.TemporaryDirectory() as d:
        gh("run", "download", run_id, "-R", repo, "-D", d)
        files = [p for p in pathlib.Path(d).rglob("*") if p.is_file()]
        if not files:
            problems.append("no artifacts to check")
        for p in files:
            for i in hits(p.read_text(errors="replace"), pats):
                problems.append(f"LEAK in artifact {p.relative_to(d)}: canary #{i}")
        print(f"checked {len(files)} artifact file(s)")

    # 3. Findings issues on the sandbox's public repos, which anyone can read.
    public = json.loads(gh("api", f"orgs/{ORG}/repos?type=public&per_page=100"))
    for r in public:
        issues = json.loads(gh("api", f"repos/{ORG}/{r['name']}/issues?state=all&labels=baseliner&per_page=100"))
        for iss in issues:
            for i in hits((iss.get("title") or "") + (iss.get("body") or ""), pats):
                problems.append(f"LEAK in a findings issue on public repo {r['name']}: canary #{i}")
    print(f"checked findings issues on {len(public)} public repo(s)")

    for p in problems:
        print(f"::error::{p}")
    if problems:
        sys.exit(1)
    print("no private repo name or canary in any public output")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "present":
        present(sys.argv[2])
    elif len(sys.argv) == 2 and sys.argv[1] == "run":
        run()
    else:
        sys.exit(__doc__)
