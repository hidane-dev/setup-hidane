#!/usr/bin/env bash
# Opens a pull request with the changes `hidane migrate` proposes, for the migrate action
# (migrate/action.yml), which passes its inputs as SETUP_HIDANE_MIGRATE_*.
#
# hidane makes the plan and the edits; this script detects and edits nothing itself. It asks
# `hidane migrate --format json` for the plan from the tip of the base branch, stops when there is
# nothing to change, applies the plan with `--apply` on a new branch, commits exactly the files
# hidane wrote, pushes the branch, which must not exist yet, and opens a pull request whose body is
# the plan. With dry-run, it stops after the commit and prints that body.
#
# Everything that comes from the repository (paths, branch names, the plan's text) is untrusted:
# it is checked before use, never put in a workflow command, printed to the log only with
# workflow commands stopped, and put in Markdown only inside code blocks it cannot end. The token
# is in the environment of `git fetch`, `git ls-remote`, `git push` and `gh` only, and git hooks
# are off. Written for bash 3.2, the bash of macOS runners.
set -euo pipefail

docs=https://github.com/hidane-dev/hidane/blob/main/docs/migrating.md
action_docs=https://github.com/hidane-dev/setup-hidane#migrating-to-hidane-in-a-pull-request
title="Run the Firestore emulator with hidane"

fail() {
  echo "::error title=setup-hidane/migrate::$*"
  exit 1
}
notice() { echo "::notice title=setup-hidane/migrate::$*"; }

output() {
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

# Prints a file of untrusted text to the log, with workflow commands stopped meanwhile.
untrusted() {
  local stop
  stop=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  echo "::stop-commands::$stop"
  cat "$1"
  if [[ -n $(tail -c 1 "$1") ]]; then
    echo
  fi
  echo "::$stop::"
}

# Prints a file as a fenced code block whose fence is longer than any run of backticks in it, so
# that nothing in the file can end the block: Markdown, HTML and @mentions in it stay text.
fenced() {
  local info=$1 file=$2 longest fence='```'
  longest=$(awk '{
    while (match($0, /`+/)) {
      if (RLENGTH > n) n = RLENGTH
      $0 = substr($0, RSTART + RLENGTH)
    }
  } END { print n + 0 }' "$file")
  while ((${#fence} <= longest)); do
    fence="$fence\`"
  done
  printf '%s%s\n' "$fence" "$info"
  cat "$file"
  if [[ -n $(tail -c 1 "$file") ]]; then
    echo
  fi
  printf '%s\n' "$fence"
}

# A branch name this action accepts: what git accepts, restricted to letters, digits, `.`, `_`,
# `-` and `/`, so that it is safe in a message, a URL and Markdown.
valid_branch() {
  local re='^[A-Za-z0-9][A-Za-z0-9._/-]*$'
  [[ ${#1} -le 200 && $1 =~ $re && $1 != *..* && $1 != *//* && $1 != */ && $1 != *. && $1 != *.lock && $1 != */.* ]] &&
    git check-ref-format --branch "$1" > /dev/null 2>&1
}

# Inputs. The token goes out of the environment first, so that no other command inherits it.
token=${SETUP_HIDANE_MIGRATE_TOKEN:-}
workflow_token=${SETUP_HIDANE_MIGRATE_WORKFLOW_TOKEN:-}
unset SETUP_HIDANE_MIGRATE_TOKEN SETUP_HIDANE_MIGRATE_WORKFLOW_TOKEN
with_workflow_token=false
if [[ -n $token && $token == "$workflow_token" ]]; then
  with_workflow_token=true
fi
workflow_token=

dry_run=${SETUP_HIDANE_MIGRATE_DRY_RUN:-false}
case $dry_run in
  true | false) ;;
  *) fail "the dry-run input must be true or false" ;;
esac
draft=${SETUP_HIDANE_MIGRATE_DRAFT:-true}
case $draft in
  true | false) ;;
  *) fail "the draft input must be true or false" ;;
esac
path=${SETUP_HIDANE_MIGRATE_PATH:-.}
if [[ -z $path || $path == *$'\n'* || $path == *$'\r'* || ! -d $path ]]; then
  fail "the path input must be a directory of the repository checked out"
fi
base=${SETUP_HIDANE_MIGRATE_BASE:-}
if [[ -n $base ]] && ! valid_branch "$base"; then
  fail "the base input must be a branch name made of letters, digits, '.', '_', '-' and '/'"
fi
branch=${SETUP_HIDANE_MIGRATE_BRANCH:-}
if [[ -n $branch ]] && ! valid_branch "$branch"; then
  fail "the branch input must be a branch name made of letters, digits, '.', '_', '-' and '/'"
fi

# Opt-in: changes go out only from a run someone started by hand in this repository.
if [[ $dry_run == false && ${GITHUB_EVENT_NAME:-} != workflow_dispatch ]]; then
  fail "this action pushes a branch and opens a pull request only in a workflow started by hand (on: workflow_dispatch); with dry-run: true it runs on any event"
fi
case ${RUNNER_OS:-} in
  Windows) fail "this action runs on Linux and macOS runners, such as ubuntu-latest" ;;
esac
for tool in git jq awk od; do
  command -v "$tool" > /dev/null 2>&1 || fail "$tool is not on PATH"
done
server=${GITHUB_SERVER_URL:-https://github.com}
re='^https://[A-Za-z0-9.-]+(:[0-9]+)?$'
[[ $server =~ $re ]] || fail "GITHUB_SERVER_URL is not an https URL"
repository=${GITHUB_REPOSITORY:-}
re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
[[ $repository =~ $re ]] || repository=
if [[ $dry_run == false ]]; then
  command -v gh > /dev/null 2>&1 || fail "gh is not on PATH"
  [[ -n $token ]] || fail "the token input is empty"
  [[ -n $repository ]] || fail "GITHUB_REPOSITORY is not owner/name"
fi
run_link=
re='^[0-9]+$'
if [[ -n $repository && ${GITHUB_RUN_ID:-} =~ $re ]]; then
  run_link=" in [this workflow run]($server/$repository/actions/runs/$GITHUB_RUN_ID)"
fi

# hidane, with `hidane migrate`, which the releases before 0.5.0 do not have: 0.4.0 answers
# `hidane migrate --help` with the emulator's usage, so the usage is checked.
bin=${SETUP_HIDANE_MIGRATE_BIN:-}
if [[ -z $bin ]]; then
  bin=$(command -v hidane || true)
  [[ -n $bin ]] || fail "hidane is not on PATH (hidane-version: installed uses the hidane an earlier step installed)"
fi
if [[ $bin != /* ]]; then
  bin="$PWD/$bin"
fi
version_line=$("$bin" --version) || fail "hidane --version failed"
re='^hidane ([0-9]+)\.([0-9]+)\.([0-9]+)$'
[[ $version_line =~ $re ]] || fail "hidane --version did not print a version"
major=$((10#${BASH_REMATCH[1]}))
minor=$((10#${BASH_REMATCH[2]}))
version="$major.$minor.$((10#${BASH_REMATCH[3]}))"
if ((major == 0 && minor < 4)) ||
  [[ $("$bin" migrate --help 2> /dev/null || true) != *"Usage: hidane migrate"* ]]; then
  fail "hidane $version has no hidane migrate, which is in 0.5.0 and later: set hidane-version to latest or to one of them"
fi
echo "Using hidane $version ($bin)"
output hidane-version "$version"

# The repository, with git hooks and fsmonitor off: no program from the repository or from an
# earlier step runs while this one does.
temp=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
work=$(mktemp -d "$temp/setup-hidane-migrate.XXXXXX")
mkdir "$work/hooks"
top=$(git -C "$path" rev-parse --show-toplevel 2> /dev/null) ||
  fail "the path input is not in a git work tree: check out the repository first (actions/checkout)"
prefix=$(git -C "$path" rev-parse --show-prefix)
g() { git -C "$top" -c core.hooksPath="$work/hooks" -c core.fsmonitor=false "$@"; }
# hidane, run in the project's directory, so that its reports name the files relative to it.
run_hidane() { (cd -- "$path" && "$bin" "$@"); }

# git with the token, for the remote: a credential helper reads it from the environment of this
# one command, so that it is on no command line and in no file. The authorization header that
# actions/checkout may have stored is dropped, so that the token used is this one.
net() {
  # shellcheck disable=SC2016 # The helper's shell expands these, not this one.
  GIT_TERMINAL_PROMPT=0 SETUP_HIDANE_MIGRATE_GIT_TOKEN=$token g \
    -c "http.$server/.extraheader=" \
    -c credential.helper= \
    -c "credential.$server.helper="'!f() { test "$1" = get && echo username=x-access-token && echo "password=$SETUP_HIDANE_MIGRATE_GIT_TOKEN"; }; f' \
    "$@"
}

if [[ -n $(g status --porcelain=v1 --untracked-files=no) ]]; then
  fail "the work tree has uncommitted changes: run this action on a fresh checkout, before any step that changes files"
fi
g remote get-url origin > /dev/null 2>&1 || fail "the repository has no remote named origin"

# The base branch, fetched: the changes are made from its tip on origin.
if [[ -z $base ]]; then
  base=$(g symbolic-ref --quiet --short HEAD || true)
  if [[ -z $base && ${GITHUB_REF:-} == refs/heads/* ]]; then
    base=${GITHUB_REF#refs/heads/}
  fi
  [[ -n $base ]] || fail "no branch is checked out: set the base input to the branch the pull request merges into"
  valid_branch "$base" || fail "the branch checked out has a name this action does not accept: set the base input"
fi
depth=
if [[ $(g rev-parse --is-shallow-repository) == true ]]; then
  depth=--depth=1
fi
net fetch --quiet --no-tags ${depth:+"$depth"} origin "+refs/heads/$base:refs/remotes/origin/$base" ||
  fail "could not fetch the branch $base from origin"
base_commit=$(g rev-parse --verify --quiet "refs/remotes/origin/$base^{commit}") ||
  fail "origin has no branch $base"
if [[ $(g rev-parse HEAD) != "$base_commit" ]]; then
  g -c advice.detachedHead=false switch --quiet --detach "$base_commit"
fi
echo "Base: $base at $base_commit"

# The plan.
plan="$work/plan.json"
if ! run_hidane migrate --format json > "$plan" 2> "$work/stderr.txt"; then
  untrusted "$work/stderr.txt"
  fail "hidane migrate could not make a plan"
fi
jq -e '.schema == "hidane.migrate/1" and (.files | type == "array") and (.notes | type == "array") and (.detected | type == "array")' "$plan" > /dev/null ||
  fail "hidane migrate printed a plan this action cannot read (it reads hidane.migrate/1)"

# The plan's text, for the commit message, the job summary and the pull request.
render_plan() {
  jq -r --arg prefix "$prefix" '.files[] | ($prefix + .file), (.changes[] | "  line \(.line): \(.description)")' "$1" > "$work/changes.txt"
  jq -r '.detected[] | "\(.file):\(.line): \(.what)"' "$1" > "$work/detected.txt"
  jq -r '
    {"compatible": "✓", "likely-compatible": "~", "ok": "✓", "info": "·", "unknown": "?", "incompatible": "✗"} as $marks
    | .notes[]
    | "\(if .status == "info" and .severity == "warning" then "!" else ($marks[.status] // "·") end) \(.title)",
      ((.details // [])[] | "    \(.)")' "$1" > "$work/notes.txt"
  jq -j '.patch' "$1" > "$work/patch.txt"
}
render_plan "$plan"
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

if jq -e '.files | length == 0' "$plan" > /dev/null; then
  {
    echo "### hidane migrate: nothing to change"
    echo
    echo "hidane $version found nothing to change on \`$base\` ([what it changes]($docs#what-it-changes))."
    if [[ -s $work/detected.txt ]]; then
      echo
      echo "Detected:"
      echo
      fenced text "$work/detected.txt"
    fi
    if [[ -s $work/notes.txt ]]; then
      echo
      echo "Left as it is:"
      echo
      fenced text "$work/notes.txt"
    fi
  } >> "$summary"
  output changed false
  output plan-file "$plan"
  notice "hidane migrate found nothing to change: no branch and no pull request"
  exit 0
fi

# The branch, which must not exist on origin: this action never pushes to a branch it did not
# create.
if [[ -z $branch ]]; then
  branch="hidane/migrate-${base_commit:0:7}"
fi
[[ $branch != "$base" ]] || fail "the branch input names the base branch"
existing=$(net ls-remote --heads origin "refs/heads/$branch") || fail "could not list the branches of origin"
if [[ -n $existing ]]; then
  if [[ $dry_run == false ]]; then
    url=$(GH_TOKEN=$token GH_HOST=${server#https://} GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
      gh pr list --repo "$repository" --head "$branch" --state open --json url,isCrossRepository \
      --jq 'map(select(.isCrossRepository | not)) | .[0].url // ""' 2> /dev/null || true)
    re='^https://[A-Za-z0-9.:/_-]+/pull/[0-9]+$'
    if [[ $url =~ $re ]]; then
      output changed true
      output branch "$branch"
      output pull-request-url "$url"
      notice "the branch $branch exists and is proposed in $url: nothing was pushed"
      exit 0
    fi
  fi
  fail "the branch $branch exists on origin, and this action never pushes to an existing branch: delete it, or name a new one with the branch input"
fi

# The changes, made by hidane migrate --apply, which writes the files after checking each against
# the plan and git for uncommitted changes.
g switch --quiet --create "$branch"
applied="$work/applied.json"
if ! run_hidane migrate --apply --format json > "$applied" 2> "$work/stderr.txt"; then
  untrusted "$work/stderr.txt"
  fail "hidane migrate --apply did not apply the plan: see its message above"
fi
untrusted "$work/stderr.txt"
jq -e '.schema == "hidane.migrate/1" and (.applied.written | type == "array") and ([.files[].file] == .applied.written) and (.applied.written | length > 0)' "$applied" > /dev/null ||
  fail "hidane migrate --apply did not report writing the files of its plan"
plan="$applied"
output plan-file "$plan"
render_plan "$plan"

# hidane's backup of the files, which git holds anyway, is not part of the change.
backup=$(jq -r '.applied.backup // ""' "$plan")
if [[ -n $backup ]]; then
  re='^\.hidane-backup/[0-9]{8}T[0-9]{6}Z(-[0-9]+)?$'
  [[ $backup =~ $re ]] || fail "hidane migrate reported a backup directory this action does not expect"
  (cd -- "$path" && rm -rf -- "$backup" && { rmdir .hidane-backup 2> /dev/null || true; })
fi

# Exactly the files hidane wrote: relative paths, with no line break and no `.` or `..` part,
# staged as literal paths.
jq -r --arg prefix "$prefix" '.applied.written[]
  | if test("[\\r\\n]") or any(split("/")[]; . == "" or . == "." or . == "..") then error("unexpected path") else $prefix + . end' \
  "$plan" > "$work/written.txt" 2> /dev/null || fail "hidane migrate reported a file path this action does not accept"
while IFS= read -r file; do
  g --literal-pathspecs add -- "$file"
done < "$work/written.txt"
g diff --quiet || fail "the work tree has changes hidane migrate did not report: nothing was committed"
LC_ALL=C sort < "$work/written.txt" > "$work/expected.txt"
g -c core.quotepath=off diff --cached --name-only | LC_ALL=C sort > "$work/staged.txt"
cmp -s "$work/expected.txt" "$work/staged.txt" || fail "the files staged are not the files hidane migrate wrote: nothing was committed"

{
  echo "$title"
  echo
  echo "The changes hidane migrate (hidane $version) proposed, applied by"
  echo "hidane-dev/setup-hidane/migrate:"
  echo
  cat "$work/changes.txt"
  echo
  echo "$docs"
} > "$work/message.txt"
g -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
  -c commit.gpgsign=false commit --quiet --no-verify --file="$work/message.txt"
commit=$(g rev-parse HEAD)
echo "Committed $commit on $branch"
output changed true
output branch "$branch"
output commit "$commit"

# The pull request's body.
doctor_report="$work/doctor.txt"
doctor_json="$work/doctor.json"
status=0
run_hidane doctor > "$doctor_report" 2> /dev/null || status=$?
((status <= 1)) || fail "hidane doctor failed"
status=0
run_hidane doctor --format json > "$doctor_json" 2> /dev/null || status=$?
((status <= 1)) || fail "hidane doctor failed"
jq -e '.schema == "hidane.doctor/1" and (.summary | [.compatible, .likely_compatible, .ok, .info, .unknown, .incompatible] | all(type == "number"))' "$doctor_json" > /dev/null ||
  fail "hidane doctor printed a report this action cannot read (it reads hidane.doctor/1)"
counts=$(jq -r '.summary | "\(.compatible) compatible, \(.likely_compatible) likely compatible, \(.ok) ok, \(.info) info, \(.unknown) not verified, \(.incompatible) incompatible"' "$doctor_json")
incompatible=$(jq -r '.summary.incompatible' "$doctor_json")

write_body() { # $1: with the diff, $2: with the doctor's report (true or false)
  echo "This pull request moves the project's tests from the official Firestore emulator to [hidane](https://github.com/hidane-dev/hidane), a Firestore emulator without Java. The changes are the ones \`hidane migrate\` (hidane $version) proposed, applied as they are by [hidane-dev/setup-hidane/migrate]($action_docs)$run_link: nothing else was edited."
  echo
  if ((incompatible > 0)); then
    echo '> [!WARNING]'
    echo "> \`hidane doctor\` found $incompatible incompatible $(if ((incompatible == 1)); then echo finding; else echo findings; fi) in this project: read its report below before merging."
    echo
  fi
  echo "### Changes"
  echo
  fenced text "$work/changes.txt"
  echo
  echo "[What it changes]($docs#what-it-changes) describes each kind of change."
  echo
  echo "### Left as it is"
  echo
  if [[ -s $work/notes.txt ]]; then
    echo "What \`hidane migrate\` leaves to you, and why ([what it leaves to you]($docs#what-it-leaves-to-you)):"
    echo
    fenced text "$work/notes.txt"
  else
    echo "Nothing: \`hidane migrate\` left nothing to you."
  fi
  echo
  echo "### Diff"
  echo
  if [[ $1 == true ]]; then
    fenced diff "$work/patch.txt"
  else
    echo "The diff is too long for this description: see the commit."
  fi
  echo
  echo "### hidane doctor"
  echo
  echo "On this branch: $counts."
  if [[ $2 == true ]]; then
    echo
    echo "<details><summary>The report</summary>"
    echo
    fenced text "$doctor_report"
    echo
    echo "</details>"
  fi
  if [[ -s $work/detected.txt ]]; then
    echo
    echo "<details><summary>What hidane migrate detected</summary>"
    echo
    fenced text "$work/detected.txt"
    echo
    echo "</details>"
  fi
  echo
  echo "### Reviewing"
  echo
  echo "- The diff above is the whole change. Your CI runs on this branch with hidane in place of the official emulator: merge once your tests pass."
  if [[ $with_workflow_token == true ]]; then
    echo "- This pull request was opened with the workflow's \`GITHUB_TOKEN\`, so no workflow has run on it: close and reopen it, or push a commit to it, to run them."
  fi
  if [[ $draft == true ]]; then
    echo "- It is a draft: mark it ready for review when you are satisfied."
  fi
  echo "- Not wanted? Close it and delete the branch \`$branch\`: nothing else was changed."
  echo "- A change that looks wrong, or a project \`hidane migrate\` should handle better: [open an issue](https://github.com/hidane-dev/hidane/issues)."
}

# GitHub takes up to 65,536 characters: without the doctor's report, then without the diff, if
# need be.
body="$work/body.md"
write_body true true > "$body"
if (($(wc -c < "$body") > 60000)); then
  write_body true false > "$body"
fi
if (($(wc -c < "$body") > 60000)); then
  write_body false false > "$body"
fi
output body-file "$body"
{
  echo "### hidane migrate: $branch"
  echo
  cat "$body"
} >> "$summary"
echo "Pull request body:"
untrusted "$body"

if [[ $dry_run == true ]]; then
  notice "dry run: the changes are committed on the local branch $branch ($commit); nothing was pushed and no pull request was opened"
  exit 0
fi

# GitHub refuses changes to .github/workflows/ pushed with the workflow's token.
if [[ $with_workflow_token == true ]] && grep -q '^\.github/workflows/' "$work/written.txt"; then
  fail "the changes include .github/workflows/, which the workflow's GITHUB_TOKEN cannot push: pass a GitHub App token or a fine-grained personal access token with the Workflows permission as the token input (see $action_docs). The job summary has the changes as a diff"
fi

# Only to the repository the workflow runs in, as actions/checkout configures it.
origin=$(g config --get remote.origin.url || true)
if [[ $origin != "$server/$repository" && $origin != "$server/$repository.git" ]]; then
  fail "origin is not $server/$repository: this action pushes only to the repository the workflow runs in"
fi
if ! net push --quiet origin "refs/heads/$branch:refs/heads/$branch" 2> "$work/stderr.txt"; then
  untrusted "$work/stderr.txt"
  if grep -q 'without .workflows. permission' "$work/stderr.txt"; then
    fail "GitHub refused the push: the token cannot change .github/workflows/. Pass a token with the Workflows permission (see $action_docs)"
  fi
  fail "could not push the branch $branch"
fi
echo "Pushed $branch"

args=(pr create --repo "$repository" --base "$base" --head "$branch" --title "$title" --body-file "$body")
if [[ $draft == true ]]; then
  args+=(--draft)
fi
compare="$server/$repository/compare/$base...$branch?expand=1"
if ! GH_TOKEN=$token GH_HOST=${server#https://} GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
  gh "${args[@]}" > "$work/gh.txt" 2> "$work/stderr.txt"; then
  untrusted "$work/stderr.txt"
  fail "pushed $branch, but could not open the pull request: open it at $compare (with the workflow's token, the repository must allow GitHub Actions to create pull requests)"
fi
url=$(grep -E '^https://[A-Za-z0-9.:/_-]+/pull/[0-9]+$' "$work/gh.txt" | tail -n 1 || true)
[[ -n $url ]] || fail "gh pr create did not print the pull request's URL: see $compare"
output pull-request-url "$url"
notice "opened $url"
