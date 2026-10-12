# setup-hidane

[![test](https://github.com/hidane-dev/setup-hidane/actions/workflows/test.yml/badge.svg)](https://github.com/hidane-dev/setup-hidane/actions/workflows/test.yml)

Installs [hidane](https://github.com/hidane-dev/hidane), a Firestore emulator without Java, in a
GitHub Actions job and puts `hidane` on `PATH`. The release archive's SHA-256 and its build
provenance are checked before anything in it runs.

```yaml
- uses: hidane-dev/setup-hidane@v1
```

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
    version: 0.3.0 # or v0.3.0
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
| `version` | `latest` | `latest`, resolved through the GitHub API (`releases/latest`), or an exact version: `0.3.0` or `v0.3.0`. Anything else is refused. |
| `verify-attestation` | `true` | `true` verifies the archive's build provenance attestation with `gh attestation verify`; when `gh` is not on `PATH` (some self-hosted runners and container jobs), the check is skipped with a notice. `false` skips it. |
| `token` | `${{ github.token }}` | Used for the GitHub API and `gh`, for public data only: the job needs no extra permissions. It is sent to github.com only. |

## Outputs

| Output | Description |
|---|---|
| `version` | The installed version, such as `0.3.0`. |
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
