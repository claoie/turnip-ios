#!/bin/sh
set -eu

# Usage: ci_scripts/test-check-privacy-manifest.sh
#
# check-privacy-manifest.sh fails open on a typo. Misspell one pattern and the
# API it covers goes unmatched, its category goes unreported, and the gate
# still prints that every referenced category is declared — so the build stays
# green on the exact violation the gate exists to stop, and the next
# observation is an ITMS-91053 rejection at upload. Nothing else re-derives
# that table, which is why every row gets a fixture that fails when the row is
# wrong.
#
# Each case builds a throwaway tree with its own manifest and sources and runs
# the gate against it with an explicit root, so no case can see the repo's real
# manifest or be affected by what the others wrote.

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
gate=$here/check-privacy-manifest.sh
[ -x "$gate" ] || { echo "no executable gate at $gate" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

passed=0
failed=0

write_manifest() {
  out=$1/Turnip/Resources/PrivacyInfo.xcprivacy
  shift
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0">' '<dict>' \
    '  <key>NSPrivacyTracking</key>' '  <false/>' \
    '  <key>NSPrivacyAccessedAPITypes</key>' '  <array>' >"$out"
  for category in "$@"; do
    printf '    <dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategory%s</string><key>NSPrivacyAccessedAPITypeReasons</key><array><string>TEST.1</string></array></dict>\n' \
      "$category" >>"$out"
  done
  printf '%s\n' '  </array>' '</dict>' '</plist>' >>"$out"
}

new_root() {
  dir=$(mktemp -d "$tmp/case.XXXXXX")
  mkdir -p "$dir/Turnip/Resources" "$dir/Turnip/Sources"
  printf 'let placeholder = 1\n' >"$dir/Turnip/Sources/Thing.swift"
  write_manifest "$dir"
  echo "$dir"
}

write_src() {
  printf '%s\n' "$2" >"$1/Turnip/Sources/Thing.swift"
}

# check <label> <expected-exit> <root> [+substring-required | -substring-forbidden ...]
check() {
  label=$1
  want=$2
  root=$3
  shift 3
  if out=$("$gate" "$root" 2>&1); then got=0; else got=$?; fi
  ok=yes
  detail=''
  if [ "$got" != "$want" ]; then
    ok=no
    detail="exit $got, expected $want"
  fi
  for spec in "$@"; do
    needle=${spec#?}
    case $spec in
      +*)
        case $out in
          *"$needle"*) ;;
          *) ok=no; detail="${detail:+$detail; }output is missing: $needle" ;;
        esac
        ;;
      -*)
        case $out in
          *"$needle"*) ok=no; detail="${detail:+$detail; }output should not contain: $needle" ;;
        esac
        ;;
    esac
  done
  if [ "$ok" = yes ]; then
    passed=$((passed + 1))
    echo "  ok   $label"
  else
    failed=$((failed + 1))
    echo "  FAIL $label — $detail"
    printf '%s\n' "$out" | sed 's/^/         | /'
  fi
}

satisfied='every required-reason API referenced under Turnip/ is declared'
stale='declared, but nothing under Turnip/ references it'

echo "test-check-privacy-manifest:"

# A tree that calls nothing and declares nothing is the gate's quiet case: no
# violation and no staleness note, so a later note means something changed.
root=$(new_root)
check 'no required-reason API in use, nothing declared' 0 "$root" \
  "+$satisfied" -'Undeclared' "-$stale"

# One case per pattern row, each with its category undeclared, so a misspelled
# row cannot stay green.
root=$(new_root)
write_src "$root" 'init(defaults: UserDefaults = .standard)'
check 'UserDefaults undeclared' 1 "$root" \
  '+Undeclared required-reason API matching: UserDefaults' \
  '+declare NSPrivacyAccessedAPICategoryUserDefaults' \
  '+Turnip/Sources/Thing.swift'

root=$(new_root)
write_src "$root" 'let modes = UITextInputMode.activeInputModes'
check 'activeInputModes undeclared' 1 "$root" \
  '+declare NSPrivacyAccessedAPICategoryActiveKeyboards'

root=$(new_root)
write_src "$root" 'let now = ProcessInfo.processInfo.systemUptime'
check 'systemUptime undeclared' 1 "$root" \
  '+declare NSPrivacyAccessedAPICategorySystemBootTime'

root=$(new_root)
write_src "$root" 'let t = try url.resourceValues(forKeys: [.creationDateKey])'
check 'creationDateKey undeclared' 1 "$root" \
  '+declare NSPrivacyAccessedAPICategoryFileTimestamp'

# The accessor an attributesOfItem result carries. An unmatched spelling here
# is worse than a plain miss: the category is in use, so the staleness note
# below starts arguing for the removal of a declaration Apple requires.
root=$(new_root)
write_src "$root" 'let t = (attrs as NSDictionary).fileModificationDate()'
check 'fileModificationDate accessor undeclared' 1 "$root" \
  '+declare NSPrivacyAccessedAPICategoryFileTimestamp'

root=$(new_root)
write_manifest "$root" FileTimestamp
write_src "$root" 'let t = (attrs as NSDictionary).fileModificationDate()'
check 'fileModificationDate accessor declared is not reported stale' 0 "$root" \
  "+$satisfied" "-$stale"

root=$(new_root)
write_src "$root" 'let free = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])'
check 'volumeAvailableCapacityKey undeclared' 1 "$root" \
  '+declare NSPrivacyAccessedAPICategoryDiskSpace'

# The getattrlist family sits under both reason tables, so the gate names both
# and the developer records which one applies.
root=$(new_root)
write_src "$root" 'let rc = getattrlist(path, &list, &buf, size, 0)'
check 'getattrlist undeclared names both categories' 1 "$root" \
  '+declare NSPrivacyAccessedAPICategoryFileTimestamp' \
  '+declare NSPrivacyAccessedAPICategoryDiskSpace'

# Anchoring: an identifier that merely ends in a matched spelling is not a call
# to it, and a gate that fired on one would cost a declaration with no call
# site behind it.
root=$(new_root)
write_src "$root" 'func readattrlist() {} // and let d = profileModificationDate'
check 'identifier merely ending in a spelling does not match' 0 "$root" \
  "+$satisfied" -'Undeclared'

# A declared category nothing calls is a note, not a failure: Apple rejects
# undeclared usage, not an unused declaration.
root=$(new_root)
write_manifest "$root" DiskSpace
check 'declaration with no call site is a note, not a failure' 0 "$root" \
  "+$stale" '+NSPrivacyAccessedAPICategoryDiskSpace' "+$satisfied"

# The manifest's own comment names the APIs it covers, so scanning it as a
# source file would report every declared category as a use of itself.
root=$(new_root)
cat >>"$root/Turnip/Resources/PrivacyInfo.xcprivacy" <<'XML'
<!-- UserDefaults, systemUptime, .creationDateKey -->
XML
check 'the manifest is not scanned as a source file' 0 "$root" \
  "+$satisfied" -'Undeclared'

# Image assets live under Turnip/ and a short anchored pattern can match
# compressed bytes, which is a hit with no call site behind it.
root=$(new_root)
printf 'UserDefaults\000\001\002binary\n' >"$root/Turnip/Resources/blob.bin"
check 'a binary asset carrying the bytes is skipped' 0 "$root" \
  "+$satisfied" -'Undeclared'

# ...and skipping binaries must not blind the scan to the same string in source.
root=$(new_root)
printf 'UserDefaults\000\001\002binary\n' >"$root/Turnip/Resources/blob.bin"
write_src "$root" 'let store = UserDefaults.standard'
check 'the same string in a source file still matches' 1 "$root" \
  '+declare NSPrivacyAccessedAPICategoryUserDefaults'

# With the declarations key absent the gate re-derives the audit table from the
# tree: every in-use category is reported and nothing else is.
root=$(new_root)
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0">' \
  '<dict><key>NSPrivacyTracking</key><false/></dict>' '</plist>' \
  >"$root/Turnip/Resources/PrivacyInfo.xcprivacy"
write_src "$root" 'let s = UserDefaults.standard; let t = ProcessInfo.processInfo.systemUptime; let k: URLResourceKey = .creationDateKey'
check 'declarations key absent reports exactly the categories in use' 1 "$root" \
  '+declare NSPrivacyAccessedAPICategoryUserDefaults' \
  '+declare NSPrivacyAccessedAPICategorySystemBootTime' \
  '+declare NSPrivacyAccessedAPICategoryFileTimestamp' \
  -'NSPrivacyAccessedAPICategoryDiskSpace' \
  -'NSPrivacyAccessedAPICategoryActiveKeyboards'

# A manifest Xcode cannot parse is dropped from the build, which reaches App
# Store Connect as declaring nothing at all — a failure, not a note.
root=$(new_root)
printf '%s\n' '<plist version="1.0"><dict>' >"$root/Turnip/Resources/PrivacyInfo.xcprivacy"
check 'a manifest that does not parse fails' 1 "$root" \
  '+is not a valid property list'

# Exit 2 is the check itself not running, which must stay distinguishable from
# exit 1: a missing manifest is not a clean tree.
root=$(new_root)
rm "$root/Turnip/Resources/PrivacyInfo.xcprivacy"
check 'a missing manifest is a could-not-run' 2 "$root" \
  '+no privacy manifest at'

echo "test-check-privacy-manifest: $passed passed, $failed failed."
[ "$failed" -eq 0 ]
