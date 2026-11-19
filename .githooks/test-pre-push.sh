#!/bin/sh
# Tests the pre-push hook's refuse paths: sh .githooks/test-pre-push.sh
#
# It copies .githooks/pre-push out of this repository, replaces this
# repository's checks and fingerprint (the part above "shared by every
# repository's hook") with stubs in that copy only, and drives the copy
# against a scratch repository in a temporary folder. This repository and
# its stamps are never touched, and the real hook gains no switch.

hook="$(cd "$(dirname "$0")" && pwd)/pre-push"
[ -f "$hook" ] || { echo "no hook at $hook" >&2; exit 1; }

# Never act on this repository through git's hook variables.
for v in $(git rev-parse --local-env-vars 2>/dev/null); do unset "$v"; done

work=$(mktemp -d "${TMPDIR:-/tmp}/prepush-test.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# The stubs: run_checks counts its runs and runs $work/stub; the fingerprint
# is the content of $work/fp.
awk -v work="$work" '
  /^# ---- this repository.s checks/ { skip = 1
    print "run_checks() {"
    print "  n=$(cat \"" work "/runs\" 2>/dev/null || echo 0); echo $((n + 1)) > \"" work "/runs\""
    print "  sh \"" work "/stub\""
    print "}"
    print "deps_fingerprint() { cat \"" work "/fp\"; }"
    next }
  /^# ---- shared by every repository/ { skip = 0 }
  !skip { print }
' "$hook" > "$work/hook"
grep -q 'sh "'"$work"'/stub"' "$work/hook" || { echo "the hook has no checks section to stub" >&2; exit 1; }

repo="$work/repo"
git init -q "$repo"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name test
printf 'one\n' > "$repo/tracked.txt"
printf 'ignored.txt\n' > "$repo/.gitignore"
git -C "$repo" add -A && git -C "$repo" commit -q -m one
echo fp-a > "$work/fp"

fails=0
stamps() { ls "$repo/.git/prepush-passed" 2>/dev/null | wc -l | tr -d ' '; }
runs() { cat "$work/runs" 2>/dev/null || echo 0; }
push() { # push [sha]: the hook's exit status for a push of sha (default HEAD)
  sha=${1:-$(git -C "$repo" rev-parse HEAD)}
  (cd "$repo" && printf 'refs/heads/main %s refs/heads/main 0000000000000000000000000000000000000000\n' "$sha" | sh "$work/hook" origin x >/dev/null 2>&1)
}
check() { # check <name> <expected status> <expected runs> <expected stamps>
  got=$?
  if [ "$got" = "$2" ] && [ "$(runs)" = "$3" ] && [ "$(stamps)" = "$4" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: status $got (want $2), runs $(runs) (want $3), stamps $(stamps) (want $4)"
    fails=$((fails + 1))
  fi
}
reset() { git -C "$repo" reset -q --hard && git -C "$repo" clean -q -fd; }

echo 'exit 1' > "$work/stub"
push; check "failing checks are refused and not stamped" 1 1 0

echo 'exit 0' > "$work/stub"
printf 'two\n' >> "$repo/tracked.txt"
push; check "a changed tracked file is refused before running" 1 1 0
reset

touch "$repo/new.txt"
push; check "an untracked file is refused before running" 1 1 0
reset

printf 'x\n' >> "$repo/tracked.txt"; git -C "$repo" add tracked.txt
push; check "a staged change is refused before running" 1 1 0
reset

old=$(git -C "$repo" rev-parse HEAD)
printf 'two\n' >> "$repo/tracked.txt"; git -C "$repo" commit -q -am two
push "$old"; check "a commit that is not HEAD is refused" 1 1 0

touch "$repo/ignored.txt"
push; check "an ignored file is fine; passing checks are stamped" 0 2 1
push; check "the same tree and toolchain again does not rerun" 0 2 1

echo fp-b > "$work/fp"
push; check "a changed lockfile or toolchain reruns" 0 3 2

echo "printf 'mid\n' >> '$repo/tracked.txt'" > "$work/stub"
printf 'three\n' >> "$repo/tracked.txt"; git -C "$repo" commit -q -am three
push; check "a file changed during the run is not stamped" 1 4 2
reset

echo "touch '$repo/during.txt'" > "$work/stub"
push; check "a file created during the run is not stamped" 1 5 2
reset

echo "printf 'four\n' >> '$repo/tracked.txt'; git -C '$repo' commit -q -am four" > "$work/stub"
push; check "a commit made during the run is not stamped" 1 6 2
git -C "$repo" reset -q --hard HEAD~1

echo "echo fp-c > '$work/fp'" > "$work/stub"
push; check "a toolchain changed during the run is not stamped" 1 7 2
echo fp-b > "$work/fp"

echo 'exit 0' > "$work/stub"
(cd "$repo" && printf 'refs/heads/gone 0000000000000000000000000000000000000000 refs/heads/gone %s\n' "$old" | sh "$work/hook" origin x >/dev/null 2>&1)
check "a branch deletion passes without running" 0 7 2

[ "$fails" = 0 ] && echo "pre-push refuse paths: all passed" || echo "pre-push refuse paths: $fails failed"
[ "$fails" = 0 ]
