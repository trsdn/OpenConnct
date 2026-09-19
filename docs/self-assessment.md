# Self-assessment against the trsdn Repository Quality Standard

- Assessed on: 2026-09-19 (first pass 2026-09-17; Agent Readiness added the
  same day; Published Site added 2026-09-19; `W04` downgraded to partial the same day when the version number was removed from the page)
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
| `S11` | pass | both workflows declare `permissions`: `ci.yml` grants `contents: read` and never writes; `pages.yml` grants `contents: read` overall and adds `pages: write` and `id-token: write` only to the deploy job, which is what Pages deployment requires |
| `S12` | pass | every action reference is a GitHub-published action on a major-version tag (`actions/checkout@v4`, `actions/configure-pages@v5`, `actions/upload-pages-artifact@v3`, `actions/deploy-pages@v4`); the `gh` CLI is used directly, not through a third-party action |
| `S13` | n/a | neither workflow triggers on `pull_request_target` or `workflow_run`; `pages.yml` runs on `push`, `release`, `schedule` and `workflow_dispatch` only |

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

### Published Site (`W01`–`W09`)

The landing page at <https://trsdn.github.io/OpenConnct/> (issue #13). Assessed
against the live site, not only the source. `W05` and `W06` are retired in
standard 1.12.0 and are not assessed.

| Criterion | Result | Evidence |
|---|---|---|
| `W01` | pass | `site/` is committed; `.github/workflows/pages.yml` deploys it with GitHub's own Pages actions on changes to `site/`, on a published release, and weekly; `scripts/build_site.sh` is the documented, repeatable build |
| `W02` | pass | the repository homepage field is the site URL, and the site links back from the header ("Source on GitHub") and the footer |
| `W03` | pass | the first view states the name, that it mixes several USB microphones into one virtual input for Teams, Zoom and OBS, and the status ("Maintained. Needs macOS 13 or later.") with a download button, before any scrolling |
| `W04` | partial | everything in the content baseline is there (name and one-sentence purpose, status, what it does with a real screenshot, how to get it, the `Y01` disclosure, links to the repository, licence, security policy and issues, the date the page was built) **except the version**: the standard asks the page to say which release it describes. That is left out on purpose, so that publishing a release never requires a change to the site; the download button points at the latest release instead |
| `W07` | pass | network review: `site/index.html` and `site/style.css` contain no `<script>`, no external `src`/`href`/`url()`/`@import`, no web fonts and no preconnects; the only resources are `style.css`, `assets/icon.png` and `assets/mixer.png`, all same-origin, and all four were fetched from the live site. No cookies are set (there is no script and no server code). The build date is injected at build time so the browser never has to ask another host |
| `W08` | pass | each fact appears once and depth stays in the repository: no architecture, changelog, contribution or decision-record content on the page |
| `W09` | pass | made for this project rather than left at a template default: palette taken from the app's own `Theme.swift`, one bespoke figure (two clocks drifting apart versus staying locked) built for the idea the project exists for, no framework or generator |

The accessibility criteria (`X01`–`X05`) apply to the site in full and are
still unassessed below. Known good practice already in the page: semantic
landmarks, alt text on the screenshot, a text description on the animated
figure, visible keyboard focus, contrast checked for the button and body text
in both colour schemes, and the animation stops under `prefers-reduced-motion`.
That is not the same as an assessment against `X01`–`X05`.

## Left unknown — needs a follow-up pass

These turn on judgment (does the README actually cover what `P05` asks for,
is dependency-update ownership documented for `S08`, does branch protection
exist for `S09`, do releases reproduce for the `R0x` criteria, etc.) rather
than on a fact a script can read, or simply haven't been looked at yet:

`B01`, `B02`, `B04`–`B10`, `B13`–`B16`, `P05`, `P07`–`P11`, `S01`–`S04`,
`S06`–`S10`, `D01`–`D06`, `R01`–`R08`, `I01`–`I06`, `T01`–`T05`, `W05`–`W06` (retired),
`L01`–`L07`, `X01`–`X05`, `Y01`–`Y06`, `A01`–`A04`.

