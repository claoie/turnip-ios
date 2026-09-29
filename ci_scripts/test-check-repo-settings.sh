#!/bin/sh
set -eu

# Usage: ci_scripts/test-check-repo-settings.sh
#
# Exercises ci_scripts/check-repo-settings.sh against a stubbed `gh`. The real
# endpoints answer differently for an admin caller than for anyone else, and
# the one distinction that matters — a feature that is off versus a token that
# may not ask — cannot be produced on demand against a live repository. So the
# responses are supplied here instead, one case per shape the script has to
# tell apart.
#
# Exit codes: 0 every case behaved, 1 at least one did not, 2 the test itself
# could not run.

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
subject=$repo_root/ci_scripts/check-repo-settings.sh
repo=owner/name

[ -x "$subject" ] || { echo "test-check-repo-settings: no $subject" >&2; exit 2; }
command -v jq >/dev/null 2>&1 ||
  { echo "test-check-repo-settings: jq is not installed" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'STUB'
#!/bin/sh
# Answers from $GH_STUB/<url with / replaced by _>.json, with an optional
# sibling .status file naming the HTTP code to answer with.
[ "${1:-}" = api ] || { echo "gh stub: unexpected invocation: $*" >&2; exit 90; }
shift
include=no
if [ "${1:-}" = --include ]; then
  include=yes
  shift
fi
key=$(printf '%s' "${1:-}" | tr '/' '_')
body=$GH_STUB/$key.json
code=200
if [ -f "$GH_STUB/$key.status" ]; then
  code=$(cat "$GH_STUB/$key.status")
fi
if [ "$code" = none ]; then
  # gh printing nothing at all: a network failure, not an HTTP answer.
  exit 1
fi
if [ "$include" = yes ]; then
  echo "HTTP/2.0 $code stubbed"
  if [ -f "$body" ]; then cat "$body"; fi
  exit 0
fi
if [ "$code" -ge 400 ] || [ ! -f "$body" ]; then
  echo "gh stub: HTTP $code for ${1:-}" >&2
  exit 1
fi
cat "$body"
STUB
chmod +x "$work/bin/gh"

failures=0
case_number=0

# Fixtures every case starts from: the required check present, private
# reporting on. A case overwrites whichever of them it is about.
new_case() { # -> echoes a fixture directory
  case_number=$((case_number + 1))
  dir=$work/case$case_number
  mkdir -p "$dir"
  echo '{"default_branch":"main"}' >"$dir/repos_owner_name.json"
  cat >"$dir/repos_owner_name_rules_branches_main.json" <<'JSON'
[{"type":"required_status_checks",
  "parameters":{"required_status_checks":[{"context":"build-and-test"}]}}]
JSON
  echo '{"enabled":true}' >"$dir/repos_owner_name_private-vulnerability-reporting.json"
  # No security_and_analysis by default: that is what every non-admin caller
  # receives, including the token the weekly workflow runs with.
  echo '404' >"$dir/repos_owner_name_secret-scanning_alerts.status"
  echo "$dir"
}

expect() { # label fixture-dir expected-exit expected-substring
  label=$1
  dir=$2
  want=$3
  needle=$4
  set +e
  output=$(PATH="$work/bin:$PATH" GH_STUB="$dir" "$subject" "$repo" 2>&1)
  got=$?
  set -e
  if [ "$got" -ne "$want" ]; then
    failures=$((failures + 1))
    echo "FAIL $label — expected exit $want, got $got"
    echo "$output" | sed 's/^/       /'
    return 0
  fi
  case $output in
    *"$needle"*) echo "ok   $label" ;;
    *)
      failures=$((failures + 1))
      echo "FAIL $label — exit $got was right but the report never said \"$needle\""
      echo "$output" | sed 's/^/       /'
      ;;
  esac
}

d=$(new_case)
cat >"$d/repos_owner_name.json" <<'JSON'
{"default_branch":"main",
 "security_and_analysis":{"secret_scanning":{"status":"enabled"},
                          "secret_scanning_push_protection":{"status":"enabled"}}}
JSON
expect "an admin caller seeing both features on reports no drift" \
  "$d" 0 "**Push protection** — enabled"

d=$(new_case)
cat >"$d/repos_owner_name.json" <<'JSON'
{"default_branch":"main",
 "security_and_analysis":{"secret_scanning":{"status":"enabled"},
                          "secret_scanning_push_protection":{"status":"disabled"}}}
JSON
expect "push protection off is drift even when scanning is on" \
  "$d" 1 "**Push protection** — \`disabled\`"

d=$(new_case)
echo '200' >"$d/repos_owner_name_secret-scanning_alerts.status"
echo '[]' >"$d/repos_owner_name_secret-scanning_alerts.json"
expect "an alerts endpoint that answers means scanning is on" \
  "$d" 0 "**Secret scanning** — enabled"

d=$(new_case)
echo '200' >"$d/repos_owner_name_secret-scanning_alerts.status"
echo '[]' >"$d/repos_owner_name_secret-scanning_alerts.json"
expect "and push protection is then unknown rather than assumed" \
  "$d" 0 "**Push protection** — not readable"

d=$(new_case)
expect "a 404 from the alerts endpoint is scanning being off" \
  "$d" 1 "**Secret scanning** — disabled"

d=$(new_case)
expect "and push protection follows it down" \
  "$d" 1 "**Push protection** — off, because secret scanning is"

d=$(new_case)
echo '403' >"$d/repos_owner_name_secret-scanning_alerts.status"
expect "a token that may not ask is reported as unanswered, not as clean" \
  "$d" 0 "**Secret scanning** — not readable with this token"

d=$(new_case)
echo '500' >"$d/repos_owner_name_secret-scanning_alerts.status"
expect "any other status is a check that could not run" \
  "$d" 2 "answered HTTP 500"

d=$(new_case)
echo 'none' >"$d/repos_owner_name_secret-scanning_alerts.status"
expect "no response at all is a check that could not run" \
  "$d" 2 "no response from"

d=$(new_case)
echo '[]' >"$d/repos_owner_name_rules_branches_main.json"
expect "a branch with no required status check is still drift" \
  "$d" 1 "no rule on \`main\` requires \`build-and-test\`"

d=$(new_case)
echo '{"enabled":false}' >"$d/repos_owner_name_private-vulnerability-reporting.json"
expect "private reporting off is still drift" \
  "$d" 1 "**Private vulnerability reporting** — \`SECURITY.md\` offers"

if [ "$failures" -eq 0 ]; then
  echo "test-check-repo-settings: all cases behaved."
  exit 0
fi
echo "test-check-repo-settings: $failures case(s) did not behave." >&2
exit 1
