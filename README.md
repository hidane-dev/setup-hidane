# setup-hidane

[![test](https://github.com/hidane-dev/setup-hidane/actions/workflows/test.yml/badge.svg)](https://github.com/hidane-dev/setup-hidane/actions/workflows/test.yml)

Installs [hidane](https://github.com/hidane-dev/hidane), a Firestore emulator without Java, in a
GitHub Actions job and puts `hidane` on `PATH`. The release archive's SHA-256 and its build
provenance are checked before anything in it runs.

```yaml
- uses: hidane-dev/setup-hidane@v1
```

Its sub-action, `hidane-dev/setup-hidane/migrate@v1`, opens a pull request that moves a
repository's tests from the official emulator to hidane, when you ask for it:
[Migrating to hidane in a pull request](#migrating-to-hidane-in-a-pull-request).

## Usage

### The latest release

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: hidane-dev/setup-hidane@v1
  - run: hidane --version
```

### A pinned version

```yaml
- uses: hidane-dev/setup-hidane@v1
  with:
    version: 0.5.1 # or v0.5.1
```

### Under firebase-tools

`hidane exec` runs a command with hidane standing in for `java` and the official emulator jar, so
`firebase emulators:exec` starts hidane: no Java, and no jar is downloaded.

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: actions/setup-node@v7
    with:
      node-version: 24
  - run: npm ci # firebase-tools among the devDependencies
  - uses: hidane-dev/setup-hidane@v1
  - run: hidane exec -- npx firebase emulators:exec --only firestore --project demo-test 'npm test'
```

### On its own, with `FIRESTORE_EMULATOR_HOST`

Start hidane in the background, wait until it answers, and point the SDKs at it. Its output goes
to a file, so that it keeps running after the step ends.

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: hidane-dev/setup-hidane@v1
  - name: Start hidane
    run: |
      hidane --host 127.0.0.1 --port 8080 > hidane.log 2>&1 &
      curl -fsS --retry 30 --retry-connrefused --retry-delay 1 http://127.0.0.1:8080/
  - run: npm test
    env:
      FIRESTORE_EMULATOR_HOST: 127.0.0.1:8080
```

## Inputs

| Input | Default | Description |
|---|---|---|
| `version` | `latest` | `latest`, resolved through the GitHub API (`releases/latest`), or an exact version: `0.5.1` or `v0.5.1`. Anything else is refused. |
| `verify-attestation` | `true` | `true` verifies the archive's build provenance attestation with `gh attestation verify`; when `gh` is not on `PATH` (some self-hosted runners and container jobs), the check is skipped with a notice. `false` skips it. |
| `token` | `${{ github.token }}` | Used for the GitHub API and `gh`, for public data only: the job needs no extra permissions. It is sent to github.com only. |

## Outputs

| Output | Description |
|---|---|
| `version` | The installed version, such as `0.5.1`. |
| `path` | The absolute path of the `hidane` binary (`hidane.exe` on Windows). |
| `cache-hit` | `true` when the archive came from the runner's tool cache, `false` when it was downloaded. |

## What is verified

Each hidane release publishes one archive per platform, `sha256sums.txt`, and a
[GitHub artifact attestation](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations)
of each archive's build provenance ([how releases are built](https://github.com/hidane-dev/hidane/blob/main/docs/releasing.md)).
On every run, the action:

1. **Checks the SHA-256** of the archive against the release's `sha256sums.txt`, and fails if they
   differ or the archive is not listed.
2. **Verifies the build provenance attestation**, unless `verify-attestation` is `false`:

   ```sh
   gh attestation verify hidane-<version>-<target>.tar.gz \
     --repo hidane-dev/hidane \
     --signer-workflow hidane-dev/hidane/.github/workflows/release.yml \
     --source-ref refs/tags/v<version> \
     --deny-self-hosted-runners
   ```

   That is, the archive was built by hidane's release workflow, from the tag of the version
   asked for, on a GitHub-hosted runner. A failed verification fails the step.
3. Only then **extracts** the binary into the job's temporary directory, runs `hidane --version`
   to check that it is the version asked for, and adds its directory to `PATH`.

Verified archives are kept in the runner's tool cache (`hidane/<version>/<target>`). A cached
archive goes through the same two checks as a download (a mismatch is downloaded again), and the
binary is extracted from it afresh, so what runs has always been verified in the same job. On
GitHub-hosted runners, every job starts on a fresh machine and downloads the archive (a few
megabytes from GitHub Releases); the cache helps self-hosted runners and repeated installs in a
job.

Inputs are validated before use and passed to the script through environment variables, never
interpolated into it. The action is a composite action: one bash script, [`setup.sh`](setup.sh),
and no bundled JavaScript.

## Platforms

| Runner | Archive | Tested on |
|---|---|---|
| Linux x64 | `x86_64-unknown-linux-musl` (static, any distribution) | `ubuntu-24.04` |
| Linux arm64 | `aarch64-unknown-linux-musl` (static, any distribution) | `ubuntu-24.04-arm` |
| macOS arm64 | `aarch64-apple-darwin` | `macos-14` |
| macOS x64 | `x86_64-apple-darwin` | `macos-15-intel` |
| Windows x64 | `x86_64-pc-windows-msvc` | `windows-2022` |

Other runners (Windows arm64, 32-bit) fail with a message naming the supported ones. On Apple
silicon under Rosetta, the native arm64 binary is installed. Self-hosted runners and container
jobs need `bash`, `curl` and `tar` (on Windows, Git Bash with `unzip`, `7z` or PowerShell), plus
`gh` for the attestation check.

## Pinning the action

`@v1` follows the latest 1.x release. To pin an exact release, use its commit SHA, with the version
in a comment, and let Dependabot update it:

```yaml
- uses: hidane-dev/setup-hidane@<commit-sha> # v1.0.0
```

## Migrating to hidane in a pull request

`hidane-dev/setup-hidane/migrate@v1` opens a pull request with the changes
[`hidane migrate`](https://github.com/hidane-dev/hidane/blob/main/docs/migrating.md) proposes for
your repository: `hidane exec --` before `firebase emulators:exec` and `emulators:start`, and
`hidane-dev/setup-hidane@v1` in place of `actions/setup-java` where Java was there only for the
Firestore emulator. hidane makes the plan and the edits; the action applies them on a new branch,
commits, pushes and opens the pull request.

It is opt-in: it runs when you start the workflow below by hand (`workflow_dispatch`), in your
repository, and never on a schedule or on any other event. `hidane migrate` is in hidane 0.5.0
and later; with an earlier release, the action stops and says so.

### The workflow

Save it as `.github/workflows/hidane-migrate.yml`, then run it from the repository's Actions tab
(**Migrate to hidane**, **Run workflow**):

```yaml
name: Migrate to hidane

on:
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

jobs:
  migrate:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - uses: hidane-dev/setup-hidane/migrate@v1
```

To see the pull request first without opening it, add `with: { dry-run: true }`: the job summary
shows its body, and nothing is pushed.

### Tokens

By default the action uses the workflow's `GITHUB_TOKEN`, with the two permissions above. GitHub
limits that token in two ways that matter here:

- **It cannot push changes to `.github/workflows/`**, and most migrations change a workflow. The
  action then stops before pushing anything; the job summary holds the changes as a diff, for
  `git apply`.
- **The pull requests it opens start no workflow**, so your CI does not run on the branch until
  you close and reopen the pull request or push a commit to it. The repository must also allow
  GitHub Actions to create pull requests (Settings, Actions, General, Workflow permissions).

A GitHub App's token or a fine-grained personal access token has neither limit. Either needs, on
this repository only, read and write access to **Contents**, **Pull requests** and **Workflows**.
With an app, install it on the repository, keep its client ID in a variable and its private key in
a secret, and let [`actions/create-github-app-token`](https://github.com/actions/create-github-app-token)
make a token for the job; the workflow's own token then only reads:

```yaml
permissions:
  contents: read

jobs:
  migrate:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - id: app
        uses: actions/create-github-app-token@v3
        with:
          client-id: ${{ vars.HIDANE_MIGRATE_CLIENT_ID }}
          private-key: ${{ secrets.HIDANE_MIGRATE_PRIVATE_KEY }}
          permission-contents: write
          permission-pull-requests: write
          permission-workflows: write
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - uses: hidane-dev/setup-hidane/migrate@v1
        with:
          token: ${{ steps.app.outputs.token }}
```

With a personal access token, store it as a secret and pass it the same way:
`token: ${{ secrets.HIDANE_MIGRATE_TOKEN }}`.

### What it does

1. Installs hidane, with the same checks as `hidane-dev/setup-hidane` (`hidane-version`).
2. Fetches the tip of the base branch from `origin` and runs `hidane migrate --format json` there.
   When there is nothing to change, it stops, and says so in the job summary.
3. Creates the branch, `hidane/migrate-<the first seven characters of the base commit>` unless
   `branch` names another, and applies the plan with `hidane migrate --apply`. It commits exactly
   the files hidane wrote, as `github-actions[bot]`; hidane's backup (`.hidane-backup/`) is not
   committed, since git holds the files as they were.
4. Pushes the branch. A branch that already exists is never pushed to, and never force-pushed: when
   it has an open pull request, the action names it and stops; otherwise it fails.
5. Opens the pull request, a draft unless `draft` is `false`, into the base branch.

The action detects and edits nothing itself, and it refuses to run on a work tree with
uncommitted changes, so that the commit holds hidane's changes and nothing else.

### Reviewing the pull request

Its description is the plan, from `hidane migrate`'s JSON:

- **Changes**: each file and what changed in it, by line;
  [what it changes](https://github.com/hidane-dev/hidane/blob/main/docs/migrating.md#what-it-changes)
  describes each kind of change.
- **Left as it is**: what `hidane migrate` leaves to you, and why, such as installing hidane where
  an npm script now runs `hidane exec`
  ([what it leaves to you](https://github.com/hidane-dev/hidane/blob/main/docs/migrating.md#what-it-leaves-to-you)).
- **Diff**: the whole change.
- **hidane doctor**: its report on the branch, with a warning at the top when it finds something
  incompatible.

Let your CI run on the branch: its tests now start hidane in place of the official emulator. If
you do not want the change, close the pull request and delete the branch; nothing else was
changed.

### Inputs of `migrate`

| Input | Default | Description |
|---|---|---|
| `token` | `${{ github.token }}` | Pushes the branch and opens the pull request. See [Tokens](#tokens). |
| `base` | the branch checked out | The branch the pull request merges into, whose tip on `origin` the changes are made from. When no branch is checked out, the branch the workflow runs on. |
| `branch` | `hidane/migrate-<commit>` | The branch to create; it must not exist on `origin`. |
| `draft` | `true` | Open the pull request as a draft. Private repositories on some plans have no drafts: set `false` there. |
| `hidane-version` | `latest` | `latest`, an exact version such as `0.5.1`, or `installed` for the `hidane` an earlier step put on `PATH`. |
| `path` | `.` | The project's directory in the repository, as `hidane migrate --path` takes it. |
| `dry-run` | `false` | `true` commits on a local branch and prints the pull request's body to the log and the job summary, without pushing or opening anything. It is the only mode that runs on events other than `workflow_dispatch`. |

Branch names are limited to letters, digits, `.`, `_`, `-` and `/`.

### Outputs of `migrate`

| Output | Description |
|---|---|
| `changed` | `true` when `hidane migrate` proposed changes, `false` when it found nothing to change. |
| `branch` | The branch with the changes. |
| `commit` | The commit with the changes. |
| `pull-request-url` | The pull request opened, or the open one the branch already had; empty in a dry run. |
| `body-file` | The pull request's body, a Markdown file. |
| `plan-file` | The plan, as `hidane migrate --format json` printed it (`hidane.migrate/1`). |
| `hidane-version` | The version of hidane that made the plan. |

### How it handles your repository

Everything that comes from the repository (paths, branch names, the plan's text) is treated as
untrusted. Inputs are validated and passed to [`migrate/migrate.sh`](migrate/migrate.sh) through
environment variables, never interpolated into it. The plan's text goes into the pull request
inside code blocks with a fence longer than any run of backticks in it, so Markdown, HTML and
@mentions in your files stay text, and into the log only with workflow commands stopped. The token
is in the environment of `git fetch`, `git ls-remote`, `git push` and `gh` only (through a
credential helper, never on a command line), and git hooks are off while the action runs. It
pushes only to `origin` when that is the repository the workflow runs in, and only a branch it
created. It runs on Linux and macOS runners and needs `git`, `jq` and `gh`, which GitHub-hosted
runners have.

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in
the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without
any additional terms or conditions.

## Trademarks

hidane is an independent open-source project, not affiliated with Google; Firebase and Cloud
Firestore are trademarks of Google LLC.
