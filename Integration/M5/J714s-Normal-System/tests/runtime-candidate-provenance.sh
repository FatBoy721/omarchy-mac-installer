#!/bin/bash
# Candidate provenance is refused before payload staging on a wrong or dirty tree.
set -euo pipefail
recipes=${1:?Pass the prepared pkgbuilds directory}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/source/omarchy"
git -C "$T/source/omarchy" init -q
git -C "$T/source/omarchy" -c user.name=Fixture -c user.email=fixture@example.invalid \
  -c commit.gpgsign=false commit -q --allow-empty -m fixture

for candidate_package in omarchy omarchy-settings; do
  (
    export CARCH=aarch64
    unset OMARCHY_SRC
    source "$recipes/$candidate_package/PKGBUILD"
    srcdir=$T/source
    pkgdir=$T/payload-$candidate_package
    mkdir -p "$pkgdir"
    if package > "$T/wrong.log" 2>&1; then
      echo 'FAIL: a different source commit was accepted' >&2
      exit 1
    fi
    grep -q 'source revision does not match its pin' "$T/wrong.log"
    [[ ! -e $pkgdir/usr/share/doc/$candidate_package/source-revision ]]
    _commit=$(git -C "$srcdir/omarchy" rev-parse HEAD)
    printf 'fixture\n' > "$srcdir/omarchy/untracked-fixture"
    if package > "$T/dirty.log" 2>&1; then
      echo 'FAIL: a dirty source tree was accepted' >&2
      exit 1
    fi
    grep -q 'requires a clean pinned source tree' "$T/dirty.log"
    [[ ! -e $pkgdir/usr/share/doc/$candidate_package/source-revision ]]
    rm "$srcdir/omarchy/untracked-fixture"
  )
done
echo 'PASS: both runtime provenance writers reject wrong and dirty source trees'
