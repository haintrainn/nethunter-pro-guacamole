#!/bin/sh
# Build the sm8150 mainline kernel for the OnePlus 7 Pro (guacamole) as
# Debian packages, inside a Kali container (podman or docker).
#
# Output: kernel/out/linux-image-*.deb
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC=linux-v6.17.0-sm8150
URL="https://gitlab.com/sm8150-mainline/linux/-/archive/v6.17.0-sm8150/$SRC.tar.gz"
# Same tarball and checksum as postmarketOS' linux-postmarketos-qcom-sm8150
SHA512=274270bb0391bca972b1dffae778ff6fc372457b658e9252104d9894c9f24739e25df7021378cf0ac9c650cc417d0cdcdf1baa88bfdcd494920ee183298e1f34
IMAGE=kali-kernel-builder
ENGINE="${CONTAINER:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}"

if [ ! -f "$HERE/$SRC.tar.gz" ]; then
	echo "Downloading $SRC.tar.gz..."
	curl -fL -o "$HERE/$SRC.tar.gz" "$URL"
fi
echo "$SHA512  $HERE/$SRC.tar.gz" | sha512sum -c -

# Fresh checkout: extract the pinned tarball and apply pmOS + our patches
if [ ! -d "$HERE/$SRC" ]; then
	tar -C "$HERE" -xzf "$HERE/$SRC.tar.gz"
	for p in "$HERE"/pmos/*.patch "$HERE"/patches/*.patch; do
		echo "Applying $(basename "$p")"
		patch -d "$HERE/$SRC" -p1 < "$p"
	done
fi

if ! $ENGINE image exists "$IMAGE" 2>/dev/null &&
   ! $ENGINE image inspect "$IMAGE" >/dev/null 2>&1; then
	$ENGINE build -t "$IMAGE" -f - "$HERE" <<'EOF'
FROM docker.io/kalilinux/kali-rolling
RUN apt-get update && apt-get install -y --no-install-recommends \
	bc bison build-essential clang cpio debhelper dpkg-dev flex kmod \
	libelf-dev libssl-dev lld llvm python3 rsync
EOF
fi

$ENGINE run --rm -v "$HERE:/work:z" -w "/work/$SRC" "$IMAGE" sh -ec '
	export ARCH=arm64 LLVM=1
	cp ../pmos/config-postmarketos-qcom-sm8150.aarch64 .config
	scripts/kconfig/merge_config.sh -m .config ../nethunter.config
	make olddefconfig
	scripts/config --file .config --set-str LOCALVERSION "-sm8150-otg0010"
	scripts/config --file .config --disable LOCALVERSION_AUTO
	make olddefconfig
	make syncconfig
	# No linux-headers package: it needs a gcc cross toolchain (we use LLVM).
	# -d: skip dpkg build-dep check (libdw-dev etc. are not needed here)
	make -j"$(nproc)" KDEB_PKGVERSION=6.17.0-1 DPKG_FLAGS=-d \
		DEB_BUILD_PROFILES=pkg.linux-upstream.nokernelheaders bindeb-pkg
	mkdir -p ../out
	mv ../linux-image-*.deb ../linux-libc-dev_*.deb ../out/ 2>/dev/null || true
	rm -f ../linux-upstream_* ../*.buildinfo ../*.changes
'

ls -l "$HERE/out"
