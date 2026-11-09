#!/bin/bash
# Verify one matching J714s runtime and headers split-package build.
set -euo pipefail

fail() {
  printf 'native-j714s-headers: %s\n' "$*" >&2
  exit 1
}

if (( $# != 1 )) || [[ ! -d $1 ]]; then
  fail 'usage: native-headers-check.sh /directory/containing/packages'
fi
packages=$(realpath "$1")
runtime_packages=()
headers_packages=()
for archive in "$packages"/*.pkg.tar.zst; do
  [[ -f $archive ]] || continue
  case $(bsdtar -xOf "$archive" .PKGINFO | sed -n 's/^pkgname = //p') in
    linux-aurora) runtime_packages+=("$archive") ;;
    linux-aurora-headers) headers_packages+=("$archive") ;;
  esac
done
(( ${#runtime_packages[@]} == 1 )) || fail 'expected exactly one archive whose .PKGINFO names linux-aurora'
(( ${#headers_packages[@]} == 1 )) || fail 'expected exactly one archive whose .PKGINFO names linux-aurora-headers'

expected_pkgver='7.3.0.aurora15.j714s2-1'
expected_release='7.3.0-15.j714s2-1-j714s-candidate-ARCH'
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/runtime" "$work/headers" "$work/external-module"

pkginfo_value() {
  local archive=$1 key=$2
  bsdtar -xOf "$archive" .PKGINFO | sed -n "s/^${key} = //p"
}

check_pkginfo() {
  local archive=$1 name=$2
  [[ $(pkginfo_value "$archive" pkgname) == "$name" ]] || fail "$name archive has unexpected package name"
  [[ $(pkginfo_value "$archive" pkgbase) == linux-aurora ]] || fail "$name archive has unexpected package base"
  [[ $(pkginfo_value "$archive" pkgver) == "$expected_pkgver" ]] || fail "$name archive has unexpected package version"
  [[ $(pkginfo_value "$archive" arch) == aarch64 ]] || fail "$name archive is not aarch64"
}

check_pkginfo "${runtime_packages[0]}" linux-aurora
check_pkginfo "${headers_packages[0]}" linux-aurora-headers
bsdtar -xf "${runtime_packages[0]}" -C "$work/runtime"
bsdtar -xf "${headers_packages[0]}" -C "$work/headers"

runtime_root=$work/runtime/usr/lib/modules/$expected_release
headers_root=$work/headers/usr/lib/modules/$expected_release/build
[[ -s $runtime_root/version ]] || fail 'runtime package is missing its release version file'
[[ $(<"$runtime_root/version") == "$expected_release" ]] || fail 'runtime package release file differs from its module directory'
[[ -s $runtime_root/pkgbase && $(<"$runtime_root/pkgbase") == linux-aurora ]] || fail 'runtime package has no matching pkgbase file'
[[ -s $runtime_root/vmlinuz ]] || fail 'runtime package is missing vmlinuz'
[[ -s $runtime_root/modules.dep && -s $runtime_root/modules.alias ]] || fail 'runtime package is missing module dependency metadata'
[[ -n $(find "$runtime_root" -type f \( -name '*.ko' -o -name '*.ko.zst' -o -name '*.ko.xz' -o -name '*.ko.gz' \) -print -quit) ]] || fail 'runtime package contains no loadable kernel module files'
[[ -n $(find "$runtime_root/dtbs" -type f -name '*t6050*.dtb' -print -quit 2>/dev/null) ]] || fail 'runtime package has no T6050 device tree'

for required in Makefile .config Module.symvers System.map version vmlinux include/generated/autoconf.h arch/arm64/include; do
  [[ -e $headers_root/$required ]] || fail "headers package is missing $required"
done
[[ $(<"$headers_root/version") == "$expected_release" ]] || fail 'headers release file differs from runtime package'
grep -qx 'CONFIG_MODULES=y' "$headers_root/.config" || fail 'headers configuration does not enable modules'

elf_count=0
check_elf() {
  local path=$1 machine
  machine=$(readelf -h "$path" | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')
  [[ $machine == AArch64 ]] || fail "packaged ELF is not AArch64: $path ($machine)"
  ((elf_count += 1))
}

audit_tree() {
  local root=$1 path kind temp
  while IFS= read -r -d '' path; do
    case "$path" in
      *.ko.zst)
        temp=$work/module-elf
        zstd -q -d -c -- "$path" > "$temp"
        [[ $(file -b "$temp") == ELF* ]] || fail "compressed module is not ELF: $path"
        check_elf "$temp"
        ;;
      *.ko.xz)
        temp=$work/module-elf
        xz -d -c -- "$path" > "$temp"
        [[ $(file -b "$temp") == ELF* ]] || fail "compressed module is not ELF: $path"
        check_elf "$temp"
        ;;
      *.ko.gz)
        temp=$work/module-elf
        gzip -d -c -- "$path" > "$temp"
        [[ $(file -b "$temp") == ELF* ]] || fail "compressed module is not ELF: $path"
        check_elf "$temp"
        ;;
      *)
        kind=$(file -b -- "$path")
        [[ $kind == ELF* ]] && check_elf "$path"
        ;;
    esac
  done < <(find "$root" -type f -print0)
}

audit_tree "$work/runtime"
(( elf_count > 0 )) || fail 'runtime package contains no auditable ELF files'
runtime_elf_count=$elf_count
audit_tree "$work/headers"
(( elf_count > runtime_elf_count )) || fail 'headers package contains no auditable ELF files'
headers_elf_count=$((elf_count - runtime_elf_count))

cat > "$work/external-module/Makefile" <<'EOF'
obj-m += j714s_header_probe.o
EOF
cat > "$work/external-module/j714s_header_probe.c" <<'EOF'
#include <linux/init.h>
#include <linux/module.h>

static int __init j714s_header_probe_init(void)
{
	return 0;
}

static void __exit j714s_header_probe_exit(void)
{
}

module_init(j714s_header_probe_init);
module_exit(j714s_header_probe_exit);
MODULE_LICENSE("GPL");
EOF
make -C "$headers_root" M="$work/external-module" modules
[[ -s $work/external-module/j714s_header_probe.ko ]] || fail 'external C module was not produced'
vermagic=$(modinfo -F vermagic "$work/external-module/j714s_header_probe.ko")
[[ $vermagic == "$expected_release "* ]] || fail "external module vermagic does not match $expected_release"
check_elf "$work/external-module/j714s_header_probe.ko"

printf 'PASS: matching %s runtime and headers packages\n' "$expected_pkgver"
printf 'PASS: release, T6050 DTB, module metadata and AArch64 package ELF checks\n'
printf 'PASS: external C module compiled; vermagic=%s\n' "$vermagic"
printf 'ELF files checked: runtime=%d headers=%d external-module=1\n' "$runtime_elf_count" "$headers_elf_count"
printf 'Package SHA-256:\n'
sha256sum "${runtime_packages[0]}" "${headers_packages[0]}"
