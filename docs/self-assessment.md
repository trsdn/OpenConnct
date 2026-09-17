# Self-assessment against the trsdn Repository Quality Standard

- Assessed on: 2026-09-17 (Agent Readiness section added same day, after the
  initial pass)
- Standard version: [1.12.0](https://github.com/trsdn/.github/blob/v1.12.0/docs/repository-quality-standard.md)
- State: **Needs work** — not because a known gap remains open, but because
  most criteria below are still `unknown`. A record with this much unassessed
  cannot honestly claim `Healthy`; see the standard's own guidance that "a
  record that claims certainty it does not have is worse than one that admits
  a gap."

This was produced by running the standard's own `scripts/assess.py --repo
trsdn/OpenConnct`, then closing every gap the tool found, then re-verifying
each one by hand. It is not exhaustive: only the criteria a script (or a
quick, factual check) can decide are resolved. Everything else is left
`unknown` for a follow-up assessment rather than guessed at.

## Resolved

| Criterion | Result | Evidence |
|---|---|---|
| `B03` | pass | GitHub detects `MIT` at the repository root |
| `B11` | pass | `.github/conformance.yml` exists and is dated |
| `B12` | pass | repository carries the `trsdn-standard` topic |
| `G01` | pass | `AGENTS.md` exists at the repository root, describing purpose, layout, setup/run/validate commands, and forbidden operations |
| `P01` | pass | `MIT` is OSI approved |
| `P02` | pass | `CONTRIBUTING.md` and `CODE_OF_CONDUCT.md` present and recognized by GitHub |
| `P03` | pass | `SECURITY.md` documents a private reporting process, and private vulnerability reporting is now enabled on the repository (was disabled at the time of the first assessment pass) |
| `P04` | pass | issue forms (`bug_report.yml`, `feature_request.yml`) and `PULL_REQUEST_TEMPLATE.md` present |
| `P06` | pass | GitHub's Community Standards check recognizes every community health file (100% profile) |
| `S05` | pass | secret scanning is enabled on the repository |
| `S11` | pass | both `.github/workflows/ci.yml` and `release.yml` now declare a `permissions` block (`contents: read` and `contents: write` respectively — each scoped to what the workflow does; `ci.yml` never writes to the repository, `release.yml` creates releases and uploads assets) |
| `S12` | pass | every action reference in both workflows is either a GitHub-published action on a major-version tag (`actions/checkout@v4`, `actions/upload-artifact@v4`) or invoked via the `gh` CLI, not a third-party action pinned to a mutable tag |
| `S13` | n/a | neither workflow triggers on `pull_request_target` or `workflow_run` |

### Agent Readiness (`G02`–`G08`)

Assessed by hand against `AGENTS.md`, with the validation commands actually
run from this checkout rather than assumed:

| Criterion | Result | Evidence |
|---|---|---|
| `G02` | pass | `AGENTS.md` states purpose ("What this repository is"), layout, and the authoritative setup/run/validate commands |
| `G03` | pass | `AGENTS.md`'s "Do not do these" names history rewriting/force pushes/branch deletion, secret handling, deployments/releases/repo settings changes, and data-destructive commands (`sudo` driver install/uninstall) explicitly |
| `G04` | n/a | no tool-specific agent config (`.github/copilot-instructions.md` or equivalent) exists in this repository, so there is nothing that could diverge from `AGENTS.md` |
| `G05` | pass | `make test-all` is documented as the single validate command; run on 2026-09-17 from this checkout: `make test` (185 assertions) then `make test-driver` (384 assertions), 0 failures. `make build UNIVERSAL=1` was also run and succeeded (signed universal `dist/OpenConnct.app`) |
| `G06` | pass | `AGENTS.md`'s "Layout" section explicitly marks `dist/`, `Core/.build/`, `Update/.build/`, `tools/*/build/` as generated/never-hand-edit, matching `.gitignore` |
| `G07` | pass | commits carry `Co-Authored-By`/`Claude-Session` trailers in practice (e.g. `5934d75`), and `AGENTS.md` documents this as the attribution convention |
| `G08` | n/a | no repository-scoped GitHub App is installed or configured for this repository; agents operate through CLI/session tooling, not a `.github/github-app.yml`-configured app |

## Left unknown — needs a follow-up pass

These turn on judgment (does the README actually cover what `P05` asks for,
is dependency-update ownership documented for `S08`, does branch protection
exist for `S09`, do releases reproduce for the `R0x` criteria, etc.) rather
than on a fact a script can read, or simply haven't been looked at yet:

`B01`, `B02`, `B04`–`B10`, `B13`–`B16`, `P05`, `P07`–`P11`, `S01`–`S04`,
`S06`–`S10`, `D01`–`D06`, `R01`–`R08`, `I01`–`I06`, `T01`–`T05`, `W01`–`W09`,
`L01`–`L07`, `X01`–`X05`, `Y01`–`Y06`, `A01`–`A04`.

`W01`–`W09` (Published Sites) will only apply once the GitHub Pages site in
issue #13 exists.
