#!/usr/bin/env bash
# Installs a hidane release for the setup-hidane action (action.yml), which passes its inputs as
# SETUP_HIDANE_VERSION, SETUP_HIDANE_VERIFY_ATTESTATION and SETUP_HIDANE_TOKEN.
#
# Nothing downloaded is run, or even extracted, before the archive's SHA-256 matches the
# release's sha256sums.txt and, unless disabled, its build provenance attestation is verified.
# Both checks run on every install, including from the tool cache. Written for bash 3.2, the
# bash of macOS runners.
set -euo pipefail

repo=hidane-dev/hidane
server=https://github.com
api=https://api.github.com

fail() {
  echo "::error title=setup-hidane::$*"
  exit 1
}
notice() { echo "::notice title=setup-hidane::$*"; }
warning() { echo "::warning title=setup-hidane::$*"; }

# Paths for bash (POSIX) and for native programs and the runner (Windows-style on Windows).
if command -v cygpath >/dev/null 2>&1; then
  posix() { cygpath -u "$1"; }
  native() { cygpath -w "$1"; }
else
  posix() { printf '%s\n' "$1"; }
  native() { printf '%s\n' "$1"; }
fi

# Inputs are untrusted: check them before use, and do not echo a rejected value, which could
# carry workflow commands.
version_input=${SETUP_HIDANE_VERSION:-latest}
semver='^v?[0-9]+\.[0-9]+\.[0-9]+$'
if [[ $version_input != latest && ! $version_input =~ $semver ]]; then
  fail "the version input must be latest or an exact version such as 0.3.0 or v0.3.0"
fi
verify=${SETUP_HIDANE_VERIFY_ATTESTATION:-true}
case $verify in
  true | false) ;;
  *) fail "the verify-attestation input must be true or false" ;;
esac

# The token goes to github.com only; on GitHub Enterprise Server, github.token belongs to the
# enterprise instance.
token=
if [[ ${GITHUB_SERVER_URL:-$server} == "$server" ]]; then
  token=${SETUP_HIDANE_TOKEN:-}
fi

# The same targets as https://hidane.dev/install.sh, from the runner's OS and architecture.
os=${RUNNER_OS:-}
arch=${RUNNER_ARCH:-}
# A runner under Rosetta reports X64 on Apple silicon; the arm64 binary is the native one.
if [[ $os == macOS && $arch == X64 && "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" == 1 ]]; then
  arch=ARM64
fi
exe=
case "$os $arch" in
  "Linux X64") target=x86_64-unknown-linux-musl ;;
  "Linux ARM64") target=aarch64-unknown-linux-musl ;;
  "macOS ARM64") target=aarch64-apple-darwin ;;
  "macOS X64") target=x86_64-apple-darwin ;;
  "Windows X64") target=x86_64-pc-windows-msvc exe=.exe ;;
  *) fail "hidane has no build for $os $arch; it is released for Linux (X64, ARM64), macOS (ARM64, X64) and Windows (X64)" ;;
esac

temp=$(posix "${RUNNER_TEMP:-${TMPDIR:-/tmp}}")
work=$(mktemp -d "$temp/setup-hidane.XXXXXX")
trap 'rm -rf "$work"' EXIT

# curl reads the token from stdin, so that it is not on a command line.
curl_auth() {
  if [[ -n $token ]]; then
    printf 'header = "Authorization: Bearer %s"\n' "$token"
  fi
}

# Writes the URL to a file and prints the HTTP status (000 when no response came).
fetch() {
  curl -sSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
    -o "$2" -w '%{http_code}' "$1" || true
}

if [[ $version_input == latest ]]; then
  status=$(curl_auth | curl -sS --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 --config - \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    -o "$work/latest.json" -w '%{http_code}' "$api/repos/$repo/releases/latest" || true)
  [[ $status == 200 ]] || fail "could not read the latest release of $repo from the GitHub API (HTTP $status)"
  tag=$(tr -d '\r\n' < "$work/latest.json" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/' || true)
  [[ $tag =~ $semver ]] || fail "the latest release of $repo has no tag of the form vX.Y.Z"
  version=${tag#v}
else
  version=${version_input#v}
fi

if [[ $target == *windows* ]]; then
  archive="hidane-$version-$target.zip"
else
  archive="hidane-$version-$target.tar.gz"
fi
release="$server/$repo/releases/download/v$version"
echo "hidane $version for $target"

status=$(fetch "$release/sha256sums.txt" "$work/sha256sums.txt")
case $status in
  200) ;;
  404) fail "hidane $version has no release: $release/sha256sums.txt is not found" ;;
  *) fail "could not download $release/sha256sums.txt (HTTP $status)" ;;
esac
expected=$(awk -v f="$archive" '$2 == f || $2 == "*" f { print $1 }' "$work/sha256sums.txt")
[[ $expected =~ ^[0-9a-f]{64}$ ]] || fail "hidane $version has no $target build: $archive is not listed once in sha256sums.txt"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | awk '{ print $1 }'
  else
    shasum -a 256 < "$1" | awk '{ print $1 }'
  fi
}

# The tool cache keeps verified archives, keyed by version and target, in the layout of
# @actions/tool-cache. A cached archive is copied out first and checked like a download.
cache=
if [[ -n ${RUNNER_TOOL_CACHE:-} ]]; then
  cache="$(posix "$RUNNER_TOOL_CACHE")/hidane/$version/$target"
fi
cache_hit=false
if [[ -n $cache && -f "$cache.complete" && -f "$cache/$archive" ]]; then
  if cp "$cache/$archive" "$work/$archive" && [[ $(sha256 "$work/$archive") == "$expected" ]]; then
    cache_hit=true
    echo "Found $archive in the tool cache"
  else
    warning "the cached $archive does not match sha256sums.txt; downloading it again"
    rm -f "$work/$archive"
  fi
fi
if [[ $cache_hit == false ]]; then
  echo "Downloading $release/$archive"
  status=$(fetch "$release/$archive" "$work/$archive")
  [[ $status == 200 ]] || fail "could not download $release/$archive (HTTP $status)"
fi

actual=$(sha256 "$work/$archive")
[[ $actual == "$expected" ]] || fail "$archive has SHA-256 $actual, but sha256sums.txt lists $expected"
echo "SHA-256 of $archive matches sha256sums.txt: $actual"

# The attestation must come from hidane's release workflow, for this version's tag, on a
# GitHub-hosted runner.
if [[ $verify == false ]]; then
  echo "Build provenance not verified (verify-attestation: false)"
elif ! command -v gh >/dev/null 2>&1; then
  notice "skipped the build provenance check of $archive: gh is not on PATH (set verify-attestation: false to silence this)"
elif [[ -z $token ]]; then
  notice "skipped the build provenance check of $archive: no token for github.com (set verify-attestation: false to silence this)"
else
  if ! GH_TOKEN=$token GH_HOST=github.com GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    gh attestation verify "$(native "$work/$archive")" \
      --repo "$repo" \
      --signer-workflow "$repo/.github/workflows/release.yml" \
      --source-ref "refs/tags/v$version" \
      --deny-self-hosted-runners; then
    fail "the build provenance attestation of $archive did not verify (it needs a recent gh; verify-attestation: false skips the check)"
  fi
  echo "Build provenance of $archive verified: built by $repo/.github/workflows/release.yml from refs/tags/v$version on a GitHub-hosted runner"
fi

if [[ -n $cache && $cache_hit == false ]]; then
  if mkdir -p "$cache" &&
    cp "$work/$archive" "$cache/$archive.partial" &&
    mv -f "$cache/$archive.partial" "$cache/$archive" &&
    touch "$cache.complete"; then
    echo "Saved $archive in the tool cache"
  else
    warning "could not save $archive in the tool cache ($cache)"
  fi
fi

# Extracted afresh on every run, from the archive verified above, into this job's temp directory.
dest=$(mktemp -d "$temp/hidane-$version.XXXXXX")
if [[ $archive == *.zip ]]; then
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$work/$archive" -d "$dest"
  elif command -v 7z >/dev/null 2>&1; then
    7z x -bd -y "-o$(native "$dest")" "$(native "$work/$archive")" > /dev/null
  else
    # shellcheck disable=SC2016 # PowerShell expands $env:, not bash.
    ARCHIVE=$(native "$work/$archive") DEST=$(native "$dest") \
      powershell -NoProfile -NonInteractive -Command 'Expand-Archive -LiteralPath $env:ARCHIVE -DestinationPath $env:DEST'
  fi
else
  tar -xzf "$work/$archive" -C "$dest"
fi
dir="$dest/hidane-$version-$target"
bin="$dir/hidane$exe"
[[ -f $bin ]] || fail "$archive does not hold hidane-$version-$target/hidane$exe"
chmod 755 "$bin"

reported=$("$bin" --version)
[[ $reported == "hidane $version" ]] || fail "the binary in $archive reports \"$reported\", not \"hidane $version\""
echo "Installed $reported in $(native "$dir")"

native "$dir" >> "$GITHUB_PATH"
{
  echo "version=$version"
  echo "path=$(native "$bin")"
  echo "cache-hit=$cache_hit"
} >> "$GITHUB_OUTPUT"
