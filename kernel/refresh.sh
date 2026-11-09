#!/bin/sh
# kernel/refresh.sh COMMIT: takes Void's linux6.18 at that void-packages commit, a newer one
# than kernel/void-packages.commit as a rule: its version and checksums go into our template,
# its x86_64 config, mv-debug and patches replace ours (they are Void's, unchanged), and the
# rest of Void's template is shown as a diff against ours, for a person to read. Then build,
# as kernel/README.md says. Needs curl and python3.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
commit=${1:?usage: $0 VOID-PACKAGES-COMMIT}
pkg=linux6.18-kombain
dir=$here/srcpkgs/$pkg
raw=https://raw.githubusercontent.com/void-linux/void-packages/$commit/srcpkgs/linux6.18
api=https://api.github.com/repos/void-linux/void-packages/contents/srcpkgs/linux6.18
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "$raw/template" -o "$tmp/template"
curl -fsSL "$raw/files/x86_64-dotconfig" -o "$tmp/x86_64-dotconfig"
curl -fsSL "$raw/files/mv-debug" -o "$tmp/mv-debug"
mkdir -p "$tmp/patches"
for name in $(curl -fsSL "$api/patches?ref=$commit" | python3 -c 'import json,sys; print("\n".join(e["name"] for e in json.load(sys.stdin)))'); do
	curl -fsSL "$raw/patches/$name" -o "$tmp/patches/$name"
done

version=$(sed -n 's/^version=//p' "$tmp/template")
old=$(sed -n 's/^version=//p' "$dir/template")
python3 - "$tmp/template" "$dir/template" "$commit" <<'PY'
import re, sys
void, ours, commit = sys.argv[1:4]
v = open(void).read()
o = open(ours).read()
checksum = re.search(r'^checksum=.*?(?=\n\n)', v, re.S | re.M).group(0)
o = re.sub(r'^checksum=.*?(?=\n\n)', lambda m: checksum, o, count=1, flags=re.S | re.M)
o = re.sub(r'^version=.*$', re.search(r'^version=.*$', v, re.M).group(0), o, count=1, flags=re.M)
o = re.sub(r'\(void-packages [0-9a-f]{40}\)', f'(void-packages {commit})', o, count=1)
open(ours, 'w').write(o)
PY
cp "$tmp/x86_64-dotconfig" "$tmp/mv-debug" "$dir/files/"
rm -f "$dir"/patches/*
cp "$tmp"/patches/* "$dir/patches/"
echo "$commit" > "$here/void-packages.commit"

echo "Void's linux6.18 $version (was $old) from void-packages $commit."
echo "Our template now has its version and checksums; what else Void changed, if anything:"
diff -u "$tmp/template" "$dir/template" | grep -v -e '^[-+]# ' -e '^[-+]pkgname=' -e '^[-+]short_desc=' -e '^[-+]maintainer=' -e '^[-+]archs=' -e '^[-+]_kernver=' -e '^[-+]export KBUILD_BUILD_' -e '^[-+]linux6.18.*_package() {' || true
echo "Set revision=1 if the version moved, bump it if only the config did, then commit and dispatch the kernel workflow."
