#!/bin/bash
# Preparation stays isolated and keeps every build recipe pinned and checksummed.
set -euo pipefail

ROOT=$(realpath "${BASH_SOURCE[0]%/*}/../../../../")
CANDIDATE=$(realpath "$ROOT/Integration/M5/J714s-Normal-System")
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

XDG_CACHE_HOME="$T/cache" "$CANDIDATE/prepare" "$T/candidate"
PACKAGES="$T/candidate/pkgbuilds"
bash "$CANDIDATE/tests/runtime-candidate-provenance.sh" "$PACKAGES"

for package in m1n1-aurora uboot-aurora linux-aurora mesa-aurora omarchy-aurora-firmware omarchy omarchy-settings; do
  [[ -f $PACKAGES/$package/PKGBUILD ]]
  [[ ! -d $PACKAGES/$package/.omarchy ]]
  bash -n "$PACKAGES/$package/PKGBUILD"
done

check_recipe() {
  local package=$1 commit=$2 url=$3
  (
    cd "$PACKAGES/$package"
    export CARCH=aarch64
    source PKGBUILD
    [[ $_commit == "$commit" ]]
    local found=0
    for entry in "${source[@]}"; do
      if [[ $entry == *"git+$url.git#commit=$commit" ]]; then found=1; fi
    done
    (( found ))
    if [[ $package == omarchy || $package == omarchy-settings ]]; then
      [[ $pkgver == 4.5.0 && $pkgrel == 3.7141 && $_tag == v4.5.0 ]]
    else
      [[ $pkgver == *"j714s2"* ]]
    fi
    for index in "${!source[@]}"; do
      if [[ ${sha256sums[index]} != 'SKIP' && ${source[index]} != *'git+'* ]]; then
        printf '%s  %s\n' "${sha256sums[index]}" "${source[index]}" | sha256sum -c -
      fi
    done
  )
}

check_recipe m1n1-aurora 02785a35e046901d5686ab9059b2c08b6256752a https://github.com/omacom/m1n1
check_recipe uboot-aurora 70e990818a895454780797beedc6a7bdac9e2fd6 https://github.com/edimoldovan/u-boot
check_recipe linux-aurora 34f2f5bb4d03bbe3acce237cb67af8dc9972aa4a https://github.com/rolotrealanis98/linux
check_recipe mesa-aurora 043a4c58080c4951fea3797fe45fc6898ce77632 https://github.com/rolotrealanis98/mesa
check_recipe omarchy a948d8a6871f446b335258c827648ac5f4e9428b https://github.com/omacom/omarchy
check_recipe omarchy-settings a948d8a6871f446b335258c827648ac5f4e9428b https://github.com/omacom/omarchy

validator=$PACKAGES/m1n1-aurora/validate-qualification.py
record=$PACKAGES/m1n1-aurora/build-qualification.json
if python3 "$validator" "$record" 02785a35e046901d5686ab9059b2c08b6256752a > "$T/promotion.log" 2>&1; then
  echo 'FAIL: a hardware-unqualified candidate passed promotion validation' >&2
  exit 1
fi
grep -q 'not hardware-qualified' "$T/promotion.log"

printf 'keep\n' > "$T/candidate/sentinel"
if XDG_CACHE_HOME="$T/cache" "$CANDIDATE/prepare" "$T/candidate" > "$T/repeat.log" 2>&1; then
  echo 'FAIL: candidate preparation accepted an existing destination' >&2
  exit 1
fi
[[ $(cat "$T/candidate/sentinel") == 'keep' ]]
if "$CANDIDATE/prepare" "$ROOT/Integration/M5/J714s-Normal-System/forbidden-build" > "$T/inside.log" 2>&1; then
  echo 'FAIL: candidate preparation accepted a destination in the checkout' >&2
  exit 1
fi
[[ ! -e $ROOT/Integration/M5/J714s-Normal-System/forbidden-build ]]
echo 'PASS: recipes pinned, isolated, checksummed, provenance-tested and hardware-unqualified'
