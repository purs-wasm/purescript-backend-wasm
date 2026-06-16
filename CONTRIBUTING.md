# Contributing

The development workflow for this repository: how changes land on `main`, how commits
are named, and the checks that guard them. For the hands-on **development procedures**
(running the dev CLI, adding an intrinsic, installing a `ulib` library, running the tests,
benchmarking) see [`docs/developers-guide/development.md`](./docs/developers-guide/development.md);
for coding conventions (naming, module structure, the `unsafe` rule, tests) see
[`CLAUDE.md`](./CLAUDE.md); for design decisions see the [ADRs](./docs/design-decisions).

## Branching and pull requests

`main` is protected. All changes land through a pull request — no direct pushes, no
force-pushes, no branch deletion.

- Branch off `main`, push the branch, open a PR.
- A PR merges only when the **`ci-gate`** status check is green and the branch is up to
  date with `main`.
- Merge by **squash**; the squashed commit takes the **PR title**, so the PR title must
  follow the [commit-message convention](#commit-messages) below. Head branches are
  deleted on merge.
- Keep a PR (and ideally each commit) to a **single concern** — don't bundle, say, a CI
  change with a comment cleanup.

The PR description is pre-filled from [`.github/pull_request_template.md`](./.github/pull_request_template.md).
CI passing is enforced mechanically by `ci-gate`; the checklist there is for the
human-judgment gates (docs, tests, ADR, benchmarks, ABI impact).

## Commit messages

```
[<Category>] <scope>: <summary>
```

- **Category** — one of:
  `Feature` · `Bugfix` · `Refactor` · `Chore` · `Docs` · `Test` · `Perf` · `CI`
- **scope** — what the change touches: an ADR (`ADR-0019`), a subsystem (`Codegen`,
  `Lower`, `ulib`, `Frontend`), or `docs`.
- **summary** — imperative, concise, no trailing period.

Examples:

```
[Bugfix] ADR-0019: keep voided effects from being dropped
[Docs] compiler: remove outdated $ADT references in code comments
[Refactor] Lower: split match lowering out of Lower.purs
[CI] workflows: add the ci-gate required check
```

Notes:

- **Comment-only changes are `Docs`** (a code comment is documentation — this matches
  Conventional Commits' `docs:`), scoped by subsystem, e.g. `[Docs] Codegen: …`.
- A design change should reference its ADR in the scope.
- `Merge` / `Revert` / `fixup!` / `squash!` subjects are exempt from the format.
- The [`commit-msg` hook](#local-git-hooks) checks the subject against this format.

## Before you merge

`ci-gate` enforces the mechanical checks (compile, test, format) on every code change.
On top of that, the PR author owns these judgment calls (see the PR template):

- **Docs** — any behaviour / feature / representation change is reflected in `docs/` and
  the relevant ADR(s). The docs are kept faithful to the code; **the implementation is the
  source of truth**, not the prose.
- **Tests** — added or updated for the change. A **bug fix carries a regression guard in
  the routinely-run lane** (unit / e2e), not only in a slow or non-routine lane — a regression
  that only a slow lane catches is a regression that rides on red unnoticed.
- **ADR** — a design change has an ADR (added or updated, with its `Status` set). ADRs are
  point-in-time records: correct them in place with a struck-through (`~~…~~`) original plus
  a dated addendum rather than rewriting history (see the ADR README).
- **No perf regression** — for optimizer / runtime / lowering changes, compare benchmarks
  (`node bench/run.mjs <dir>`; never overwrite `bench/snapshots/baseline.json`).
- **GC type / ABI / canonicalization** — a change to the value-type substrate or the
  host/runtime ABI keeps cross-module type canonicalization intact.

## Local git hooks

The hooks in [`.githooks/`](./.githooks) mirror the CI gates locally for fast feedback.
Enable them once per clone:

```sh
git config core.hooksPath .githooks
```

- **`pre-commit`** — rejects Japanese (Hiragana / Katakana / Han / CJK) in *staged
  additions*. Permanent, version-controlled files are English; Japanese marks ephemeral
  scratch docs that stay out of version control.
- **`commit-msg`** — checks the commit subject against the [convention](#commit-messages).
- **`pre-push`** — runs the full suite (`compile → test → check`) for both `compiler` and
  `binaryen`, the same as CI, before any push.

The hooks are convenience and per-clone — the authoritative gate is CI's `ci-gate`, which
cannot be bypassed. In an emergency a hook can be skipped with `git commit --no-verify` /
`git push --no-verify`; CI will still have the final say.

Run the hooks from inside `nix develop` (the toolchain environment).

## Continuous integration

[`.github/workflows/ci.yaml`](./.github/workflows/ci.yaml) runs on every push and PR:

- a lightweight `changes` job decides whether anything outside `docs/` / `README.md`
  changed;
- the `ci` matrix (`compiler`, `binaryen`) runs `compile → test → check` when it did;
- **`ci-gate`** always runs and is the single required status check — green when the
  matrix passed or was skipped (docs-only), red when any leg failed. Branch protection
  requires `ci-gate`, so a docs-only PR still merges (the heavy build is skipped) while a
  failing build blocks the merge.

## Documentation language

Permanent, version-controlled documents (ADRs, `docs/`, this file, READMEs, code comments)
are written in **English**. Japanese is reserved for ephemeral, throwaway notes that are
kept out of version control; the `pre-commit` hook enforces this for staged additions.
