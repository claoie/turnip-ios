#!/bin/sh
set -eu

# Usage: ci_scripts/check-privacy-manifest.sh [repo-root]
#
# Cross-references the required-reason APIs the sources under Turnip/ reference
# against the categories Turnip/Resources/PrivacyInfo.xcprivacy declares. An
# App Store Connect or TestFlight upload of a build that calls one of these
# APIs without declaring its category is rejected at processing time with
# ITMS-91053, enforced rather than warned since 2024-05-01.
#
# Nothing else in this pipeline would catch it. CI builds and tests but never
# produces a distribution archive, so the manifest is never submitted for
# validation and the first observation of a missing declaration is the first
# upload. The audit table in docs/PRIVACY.md carried a prose instruction to
# re-run it by hand, and a prose instruction is not a gate: a feature can add a
# required-reason API, rename nothing, break no build, and leave the table
# asserting the API is unused.
#
# Matching is deliberately conservative. Patterns are matched against whole
# source files including comments and string literals, so a doc comment that
# merely names an API forces its category to be declared. That costs one dict
# in the manifest; the opposite error costs a rejected upload.
#
# Two spellings are deliberately absent, because they collide with APIs that
# are not required-reason: bare `creationDate` and `modificationDate`
# (FileAttributeKey) read identically to `PHAsset.creationDate`, which is
# PhotoKit metadata on user-granted assets. The distinctive URL-resource-key
# spellings this tree actually uses are matched, so the gap only opens if
# file-timestamp access is rewritten in the attributesOfItem style.
#
# Over-declaration is reported but does not fail: Apple rejects undeclared
# usage, not an unused declaration, so a declaration outliving its call site is
# a staleness note rather than a release blocker.
#
# Exit codes: 0 every referenced category is declared, 1 at least one is not or
# the manifest does not parse, 2 the check itself could not run.

fail() {
  echo "check-privacy-manifest: $*" >&2
  exit 2
}

root=${1:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
manifest=$root/Turnip/Resources/PrivacyInfo.xcprivacy
tree=$root/Turnip

[ -f "$manifest" ] || fail "no privacy manifest at $manifest"
[ -d "$tree" ] || fail "no Turnip directory at $tree"
command -v plutil >/dev/null 2>&1 || fail "plutil is unavailable; this check needs macOS"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

if ! plutil -lint -- "$manifest" >/dev/null 2>&1; then
  echo "Turnip/Resources/PrivacyInfo.xcprivacy is not a valid property list." >&2
  plutil -lint -- "$manifest" 2>&1 | sed 's/^/    /' >&2
  echo "  A manifest Xcode cannot parse is dropped from the build, which reaches" >&2
  echo "  App Store Connect as declaring nothing at all." >&2
  exit 1
fi

# Read declarations out of plutil's JSON rather than the XML. plutil drops
# comments, and the manifest's own comment names the categories it covers —
# grepping the file directly would let that comment satisfy this check.
if plutil -extract NSPrivacyAccessedAPITypes json -o "$workdir/types.json" -- "$manifest" >/dev/null 2>&1; then
  grep -o 'NSPrivacyAccessedAPICategory[A-Za-z]*' "$workdir/types.json" |
    sort -u >"$workdir/declared" || :
else
  : >"$workdir/declared"
fi
[ -f "$workdir/declared" ] || : >"$workdir/declared"

# One row per required-reason API spelling this tree could contain:
#
#   <ERE matched against Turnip/><TAB><space-separated categories that satisfy it>
#
# A row is satisfied when ANY of its categories is declared. The getattrlist
# family appears under both the file-timestamp and the disk-space reason tables,
# and the manifest is where the developer records which one applies. POSIX
# spellings are anchored on a non-identifier character so a Swift method whose
# name merely ends in the same letters does not match.
api_table=$(cat <<'TABLE'
UserDefaults	UserDefaults
NSUserDefaults	UserDefaults
activeInputModes	ActiveKeyboards
systemUptime	SystemBootTime
mach_absolute_time	SystemBootTime
creationDateKey	FileTimestamp
contentModificationDateKey	FileTimestamp
NSURLCreationDateKey	FileTimestamp
NSURLContentModificationDateKey	FileTimestamp
NSFileCreationDate	FileTimestamp
NSFileModificationDate	FileTimestamp
volumeAvailableCapacity	DiskSpace
volumeTotalCapacity	DiskSpace
systemFreeSize	DiskSpace
systemSize	DiskSpace
NSURLVolume(Available|Total)Capacity	DiskSpace
NSFileSystem(Free)?Size	DiskSpace
(^|[^A-Za-z0-9_])(f|l)?stat(at)?\(	FileTimestamp
(^|[^A-Za-z0-9_])f?stat(v)?fs\(	DiskSpace
(^|[^A-Za-z0-9_])(f?get)?attrlist(at|bulk)?\(	FileTimestamp DiskSpace
TABLE
)

: >"$workdir/referenced"
: >"$workdir/violations"
tab=$(printf '\t')

# The manifest's own explanatory comment names the APIs it covers, so scanning
# it as a source file would report every declared category as a use of itself.
printf '%s\n' "$api_table" | while IFS="$tab" read -r pattern categories; do
  [ -n "$pattern" ] || continue
  # -I skips binary files: image assets live under Turnip/, and a short
  # anchored pattern can match compressed bytes, which grep reports as
  # "Binary file ... matches" — a hit with no call site behind it.
  hits=$(grep -rnIE -- "$pattern" "$tree" 2>/dev/null |
    grep -v '/PrivacyInfo\.xcprivacy:' || :)
  [ -n "$hits" ] || continue

  satisfied=no
  for category in $categories; do
    echo "NSPrivacyAccessedAPICategory$category" >>"$workdir/referenced"
    if grep -qx "NSPrivacyAccessedAPICategory$category" "$workdir/declared"; then
      satisfied=yes
    fi
  done
  if [ "$satisfied" = no ]; then
    {
      echo "Undeclared required-reason API matching: $pattern"
      for category in $categories; do
        echo "  declare NSPrivacyAccessedAPICategory$category with its approved reason code"
      done
      echo "$hits" | sed "s|^$root/||" | sed 's/^/    /' | head -5
    } >>"$workdir/violations"
  fi
done

if [ -s "$workdir/violations" ]; then
  echo "Turnip/Resources/PrivacyInfo.xcprivacy does not declare every required-reason API referenced under Turnip/." >&2
  echo "An upload of this build is rejected with ITMS-91053 (Missing API declaration)." >&2
  sed 's/^/  /' "$workdir/violations" >&2
  echo "  Add each category to the manifest and update the audit table in docs/PRIVACY.md." >&2
  exit 1
fi

sort -u "$workdir/referenced" -o "$workdir/referenced"
stale=$(comm -23 "$workdir/declared" "$workdir/referenced" || :)
if [ -n "$stale" ]; then
  echo "check-privacy-manifest: declared, but nothing under Turnip/ references it —"
  echo "$stale" | sed 's/^/    /'
  echo "  Not an upload failure. Remove the declaration and its audit row once the API is gone for good."
fi

echo "check-privacy-manifest: every required-reason API referenced under Turnip/ is declared."
