# privacy-harness

An end-to-end test of baseliner's privacy guard against real private
repositories. This org, `baseliner-sandbox`, holds private fixture repos
beside its public ones. The `privacy` workflow scans the org with baseliner
in each privacy mode, then checks every public output of the run for a
private repo name or a canary string.

## What it runs

The `scan` job builds baseliner from source (`main`, or the `ref` given to a
manual run) and runs one case per matrix entry:

| Case | Settings | Expectation |
| --- | --- | --- |
| `default` | none: under GitHub Actions the guard is on | private repos masked |
| `redact` | `public_context: true`, `private_repos: redact` | private repos masked |
| `exclude` | `public_context: true`, `private_repos: exclude` | private repos absent, counted only |
| `issues` | default, real `--open-issues` on every repo | issues opened, nothing named in the log or in public repos' issues |
| `off` | `public_context: false` | every private name present, in files only |

The `off` case proves the check can see a leak. Its output names the private
repos by design, so it is written to files, checked in the job and never
printed or uploaded.

The `check` job then reads this run's scan logs and artifacts and the
findings issues on the org's public repos. It fails on any private repo name
(matched as a whole name) or the canary marker. It also fails if a guarded
case never masked a private repo, or if the expected fixtures are missing, so
it cannot pass on nothing.

The canaries are read from the API at run time and never printed. They are
not secrets: GitHub masks secret values in logs, which would hide a leak.

## Fixtures

No fixture is named in this repo. The check finds the private repos through
the API and checks that the ones the cases rely on exist:

- one that fails most checks;
- one whose `.baseliner.yml` waiver reason carries the canary marker;
- one archived;
- one whose name prefixes public repos' names, so a name cut in half would
  show.

On this free plan, private repos have no branch protection or rulesets, so
the platform checks' unreadable paths run for real.

## Setup

The workflow needs one secret, `SANDBOX_TOKEN`: a fine-grained personal
access token with resource owner `baseliner-sandbox`, access to all
repositories, and these repository permissions:

- Metadata: Read
- Contents: Read
- Actions: Read
- Administration: Read
- Issues: Read and write

It runs only on manual dispatch, on a weekly schedule and on pushes to
`main`, never on pull requests, because it holds that token. Run it against a
release candidate before tagging it:

```bash
gh workflow run privacy -R baseliner-sandbox/privacy-harness -f ref=<branch or tag>
```
