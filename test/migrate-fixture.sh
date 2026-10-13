#!/usr/bin/env bash
# Makes a fixture for the migrate action in the directory $1: a git repository, project, whose
# origin is the bare repository origin.git, both on main. $2 is the project's state:
#
#   official  firebase-tools runs the official emulator, with Java from actions/setup-java; a line
#             near the change holds a run of backticks and an @mention, which the pull request's
#             body must keep as text
#   hidane    the same project after hidane migrate: nothing to change
#   dirty     official, with an uncommitted change
set -euo pipefail

dir=$1
state=$2
case $state in
  official | dirty)
    setup='      - name: Set up Java
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: "21"'
    exec=
    ;;
  hidane)
    setup='      - name: Set up hidane
        uses: hidane-dev/setup-hidane@v1'
    exec='hidane exec -- '
    ;;
  *)
    echo "unknown state: $state" >&2
    exit 2
    ;;
esac

mkdir -p "$dir/project/.github/workflows"
git init --quiet --bare "$dir/origin.git"
cd "$dir/project"
git init --quiet
git symbolic-ref HEAD refs/heads/main

cat > firebase.json << 'JSON'
{ "emulators": { "firestore": { "port": 8080 }, "ui": { "enabled": false } } }
JSON
cat > package.json << JSON
{
  "name": "fixture",
  "private": true,
  "description": "\`\`\`\` @hidane-dev <b>text</b>",
  "scripts": {
    "test:emulator": "${exec}firebase emulators:exec --only firestore 'npm test'"
  },
  "devDependencies": { "firebase-tools": "15.33.0" }
}
JSON
cat > .github/workflows/test.yml << YAML
name: Test
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
$setup
      - run: npm ci
      - run: ${exec}npx firebase emulators:exec --only firestore "npm test"
YAML

git add firebase.json package.json .github/workflows/test.yml
git -c user.name=fixture -c user.email=fixture@example.com commit --quiet -m "A project"
git remote add origin "$dir/origin.git"
git push --quiet origin main
if [[ $state == dirty ]]; then
  echo "// changed" >> firebase.json
fi
