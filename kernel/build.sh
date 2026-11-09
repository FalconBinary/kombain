#!/bin/sh
# kernel/build.sh: builds linux6.18-kombain with xbps-src inside a Void container, the way the
# kernel workflow (.github/workflows/kernel.yml) does on GitHub Actions. Run it as root in
# ghcr.io/void-linux/void-buildroot-glibc, the image that is a bootstrapped masterdir
# (base-chroot: gcc, make, patch, chroot-git); the container itself is xbps-src's chroot
# (XBPS_CHROOT_CMD=ethereal), so no privileges beyond a plain container are needed.
#
#   sh kernel/build.sh pkg          the packages, the kernel's .config, BUILD and SHA256SUMS into $OUT
#   sh kernel/build.sh configure    stops after the kernel's .config: checks the config in minutes
#   sh kernel/build.sh show         stops after xlint and the template's metadata: what CI runs on every push
#
# BUILD (default ./kernel-build) holds void-packages at the pinned commit and the build tree;
# OUT (default $BUILD/out) receives the results; JOBS (default nproc) is make's -j.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
step=${1:-pkg}
case $step in
show | configure | pkg) ;;
*) echo "usage: $0 [show|configure|pkg]" >&2; exit 2 ;;
esac
jobs=${JOBS:-$(nproc)}
build=${BUILD:-$PWD/kernel-build}
out=${OUT:-$build/out}
pkg=linux6.18-kombain
commit=$(cat "$here/void-packages.commit")
version=$(sed -n 's/^version=//p' "$here/srcpkgs/$pkg/template")
revision=$(sed -n 's/^revision=//p' "$here/srcpkgs/$pkg/template")
kernver="$version-kombain_$revision"

echo "== tools"
export PATH=/usr/libexec/chroot-git:"$PATH"
xbps-install -Syu xbps
xbps-install -yu
# grep: the buildroot's chroot-grep has no -P, which xtools' xlint uses
xbps-install -y curl xz xtools grep
# the checkout and the build tree come in as volumes owned by someone else; git must not mind
git config --global --add safe.directory '*'

echo "== void-packages at $commit"
mkdir -p "$build" "$out"
vp=$build/void-packages
if [ ! -d "$vp/.git" ]; then
	git init -q "$vp"
	git -C "$vp" remote add origin https://github.com/void-linux/void-packages.git
fi
git -C "$vp" fetch -q --depth 1 origin "$commit"
git -C "$vp" checkout -q --detach FETCH_HEAD
# the template's directory and, as void-packages has them, a symlink to it per subpackage:
# xbps-src reads a subpackage's template through srcpkgs/<subpackage>/template
for entry in "$here"/srcpkgs/*; do
	rm -rf "$vp/srcpkgs/$(basename "$entry")"
done
cp -R "$here"/srcpkgs/* "$vp/srcpkgs/"
# do_install runs files/mv-debug through xargs; a checkout without its executable bit cost one two-hour build.
chmod +x "$vp/srcpkgs/$pkg/files/mv-debug"
cd "$vp"

echo "== xbps-src with this container as its chroot"
if ! grep -q '^XBPS_CHROOT_CMD=ethereal' etc/conf 2>/dev/null; then
	echo XBPS_CHROOT_CMD=ethereal >> etc/conf
	echo XBPS_ALLOW_CHROOT_BREAKOUT=yes >> etc/conf
fi
[ -e masterdir ] || ln -s / masterdir

echo "== the template"
xlint "srcpkgs/$pkg/template"
./xbps-src show "$pkg"
# each *_package() in the template is a subpackage; without its symlink the build fails after two hours, this fails now
for sub in $(sed -n 's/^\([a-z0-9.+_-]*\)_package() {$/\1/p' "srcpkgs/$pkg/template"); do
	./xbps-src show "$sub" | grep -E '^(pkgname|short_desc):'
done
[ "$step" != show ] || exit 0

echo "== xbps-src binary-bootstrap"
./xbps-src binary-bootstrap

echo "== xbps-src -j$jobs $step $pkg"
./xbps-src -j"$jobs" -C "$step" "$pkg"

echo "== results in $out"
src=$(find masterdir/builddir -maxdepth 1 -type d -name "$pkg-*" | head -1)
cp "$src/.config" "$out/config-$kernver"
python3 "$src/scripts/diffconfig" "srcpkgs/$pkg/files/x86_64-dotconfig" "$src/.config" > "$out/diffconfig-void-to-kombain.txt"
if [ "$step" = pkg ]; then
	cp hostdir/binpkgs/"$pkg"-"$version"_"$revision".x86_64.xbps hostdir/binpkgs/"$pkg"-headers-"$version"_"$revision".x86_64.xbps "$out/"
fi
{
	echo "package: $pkg-${version}_$revision"
	echo "kernel release: $kernver"
	echo "void-packages: $commit"
	echo "kombain: ${KOMBAIN_COMMIT:-unknown}"
	echo "compiler: $(gcc --version | head -1)"
	echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ) with -j$jobs on $(nproc) CPUs"
} > "$out/BUILD"
echo "kernel-$version-kombain-r$revision" > "$out/TAG"
(cd "$out" && rm -f SHA256SUMS && sha256sum -- * > SHA256SUMS)
ls -l "$out"
cat "$out/diffconfig-void-to-kombain.txt"
