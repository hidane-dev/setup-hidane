#!/usr/bin/env bash
# Checks a dry run of the migrate action on a fixture made by migrate-fixture.sh.
#
#   PROJECT   the fixture's project
#   EXPECTED  changed: the official project, committed on a new local branch, nothing pushed;
#             unchanged: nothing to change, no branch
#   CHANGED, BRANCH, COMMIT, PULL_REQUEST_URL, BODY_FILE, PLAN_FILE, HIDANE_VERSION  the outputs
set -euo pipefail

: "${PROJECT:?}" "${EXPECTED:?}" "${CHANGED:?}" "${PLAN_FILE:?}" "${HIDANE_VERSION:?}"

fail() {
  echo "::error::$*"
  exit 1
}

cd "$PROJECT"
main=$(git rev-parse refs/remotes/origin/main)
[[ $(git ls-remote --heads origin) == "$main	refs/heads/main" ]] || fail "origin has other branches than main"
[[ -z ${PULL_REQUEST_URL:-} ]] || fail "a dry run reported a pull request: $PULL_REQUEST_URL"
[[ -z $(git status --porcelain=v1 --untracked-files=all) ]] || fail "the work tree is not clean: $(git status --short)"
[[ ! -e .hidane-backup ]] || fail "hidane's backup is left in the project"
[[ $(jq -r .schema "$PLAN_FILE") == hidane.migrate/1 ]] || fail "the plan file is not a hidane.migrate/1 plan"
[[ $HIDANE_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "the hidane-version output is $HIDANE_VERSION"

case $EXPECTED in
  unchanged)
    [[ $CHANGED == false ]] || fail "the changed output is $CHANGED, expected false"
    [[ -z ${BRANCH:-}${COMMIT:-}${BODY_FILE:-} ]] || fail "nothing to change, but a branch, a commit or a body was reported"
    [[ $(git rev-parse HEAD) == "$main" ]] || fail "HEAD moved from origin's main"
    [[ $(git for-each-ref --format='%(refname)' refs/heads) == refs/heads/main ]] || fail "a branch was created"
    [[ $(jq '.files | length' "$PLAN_FILE") == 0 ]] || fail "the plan has changes"
    echo "Nothing to change, nothing created"
    ;;
  changed)
    [[ $CHANGED == true ]] || fail "the changed output is $CHANGED, expected true"
    [[ ${BRANCH:-} == "hidane/migrate-${main:0:7}" ]] || fail "the branch output is ${BRANCH:-}, expected hidane/migrate-${main:0:7}"
    [[ $(git symbolic-ref --short HEAD) == "$BRANCH" ]] || fail "$BRANCH is not checked out"
    [[ ${COMMIT:-} == "$(git rev-parse HEAD)" && $(git rev-parse HEAD^) == "$main" ]] || fail "the commit output is not one commit on top of origin's main"
    [[ $(git log -1 --format='%an <%ae>') == 'github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>' ]] || fail "the commit's author is $(git log -1 --format='%an <%ae>')"
    [[ $(git log -1 --format=%s) == "Run the Firestore emulator with hidane" ]] || fail "the commit's subject is $(git log -1 --format=%s)"
    [[ $(git diff --name-only HEAD^ HEAD) == $'.github/workflows/test.yml\npackage.json' ]] || fail "the commit changes $(git diff --name-only HEAD^ HEAD | tr '\n' ' ')"
    grep -q 'uses: hidane-dev/setup-hidane@v1' .github/workflows/test.yml || fail "setup-java was not replaced"
    ! grep -q setup-java .github/workflows/test.yml || fail "setup-java is still there"
    grep -q 'run: hidane exec -- npx firebase emulators:exec' .github/workflows/test.yml || fail "the workflow's command does not run under hidane exec"
    grep -q '"hidane exec -- firebase emulators:exec' package.json || fail "the npm script does not run under hidane exec"
    [[ $(jq -r '.applied.written | join(",")' "$PLAN_FILE") == ".github/workflows/test.yml,package.json" ]] || fail "the plan file is not the applied plan"

    # The body: the plan in code blocks; the diff's run of four backticks needs a fence of five.
    [[ -f ${BODY_FILE:-} ]] || fail "no body file"
    cat "$BODY_FILE"
    for heading in '### Changes' '### Left as it is' '### Diff' '### hidane doctor' '### Reviewing'; do
      grep -qxF "$heading" "$BODY_FILE" || fail "the body has no $heading"
    done
    grep -qxF '`````diff' "$BODY_FILE" || fail "the diff's fence is not longer than the backticks in it"
    grep -qF "\`$BRANCH\`" "$BODY_FILE" || fail "the body does not name the branch"
    grep -qF 'docs/migrating.md#what-it-changes' "$BODY_FILE" || fail "the body does not link docs/migrating.md"
    # Every line with the @mention is in a code block.
    awk '
      /^`{3,}/ { if (fence == "") { match($0, /^`+/); fence = substr($0, 1, RLENGTH) } else if ($0 == fence) { fence = "" }; next }
      /@hidane-dev/ && fence == "" { print "outside a code block: " $0; bad = 1 }
      END { exit bad }
    ' "$BODY_FILE" || fail "text from the repository is outside a code block"
    echo "Committed $COMMIT on $BRANCH, nothing pushed"
    ;;
  *)
    fail "EXPECTED is $EXPECTED"
    ;;
esac
