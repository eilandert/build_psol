#!/bin/bash
#
# Inside-container build driver. The docker image is already provisioned
# with the common toolchain + pagespeed deps; this script only handles
# dist-specific runtime tweaks and then drives gyp_chromium + build_psol.
#

set -e

TIME_STARTED="`date`"
NUMCORE=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
export NUMCORE

# eatmydata kills fsync globally for this shell and all children — safe
# (container is ephemeral) and a big win on the chromium-style many-
# small-files compile. We set LD_PRELOAD directly because the eatmydata
# wrapper script references a pre-multilib path that no longer exists.
LIBEAT=$(find /usr/lib -name libeatmydata.so 2>/dev/null | head -1)
[ -n "${LIBEAT}" ] && export LD_PRELOAD="${LIBEAT}"

# /etc/apt/apt.conf.d/99-build-psol is baked into the image.
apt-get update -qq

DIST=$(lsb_release -c -s)
DISTRO=$(lsb_release -is | tr A-Z a-z)   # "ubuntu" or "debian"

# ccache setup. /usr/lib/ccache is the apt-ccache shim path; CCACHE_DIR
# is set by `docker run --env` to /ccache (bind-mounted from the host)
# so the cache is shared across all dist builds and persists.
export PATH="/usr/lib/ccache:${PATH}"
export CCACHE_DIR="${CCACHE_DIR:-/ccache}"
# BASEDIR + NOHASHDIR let identical compiles in different absolute paths
# hit the same cache entry — relevant if we ever move the src tree.
export CCACHE_BASEDIR=/usr/src/incubator-pagespeed-mod
export CCACHE_NOHASHDIR=true
ccache --max-size=20G                       >/dev/null 2>&1
ccache --set-config=compression=true        >/dev/null 2>&1
ccache --set-config=compression_level=6     >/dev/null 2>&1
ccache --set-config=sloppiness=time_macros,include_file_mtime,include_file_ctime,locale,pch_defines >/dev/null 2>&1
echo "ccache stats before build:"
ccache -s | sed 's/^/  /'

# gyp_chromium hard-requires Python 2. Recent dists (bookworm, trixie,
# Ubuntu 24.04+) ship no python2 at all. Pull python2-minimal from
# Debian bullseye's archive — small, no other links.
need_bullseye_py2=no
case "$DIST" in
    bookworm|trixie|noble|resolute|oracular|plucky|questing) need_bullseye_py2=yes ;;
esac
if [ "$need_bullseye_py2" = "yes" ] && ! command -v python2 >/dev/null 2>&1; then
    echo 'deb [trusted=yes] http://archive.debian.org/debian bullseye main' \
        > /etc/apt/sources.list.d/bullseye-py2.list
    cat > /etc/apt/preferences.d/bullseye-py2 <<EOF
Package: *
Pin: release n=bullseye
Pin-Priority: 100

Package: python2 python2-minimal python2.7 python2.7-minimal libpython2.7-minimal libpython2-stdlib libpython2.7-stdlib
Pin: release n=bullseye
Pin-Priority: 900
EOF
    apt-get update -qq
fi

# Install python2 if we don't already have it. We need the full stdlib
# (not just -minimal), because gyp_chromium imports `json`. Try the full
# package first; fall back through the variants.
if ! python2 -c 'import json' >/dev/null 2>&1 && ! python2.7 -c 'import json' >/dev/null 2>&1; then
    apt-get -y install python2 2>/dev/null \
        || apt-get -y install python2.7 2>/dev/null \
        || apt-get -y install python-minimal 2>/dev/null \
        || apt-get -y install python2-minimal
    # Older dists shipped json as a separate package; install if available.
    apt-get -y install python-json 2>/dev/null || true
fi
rm -f /usr/bin/python
if [ -x /usr/bin/python2 ]; then
    ln -s /usr/bin/python2 /usr/bin/python
elif [ -x /usr/bin/python2.7 ]; then
    ln -s /usr/bin/python2.7 /usr/bin/python
else
    echo "ERROR: no python2 binary available" >&2
    exit 1
fi

# build_psol.sh references $USER. Docker containers run as root with
# USER unset, which trips `set -u` in the script.
export USER="${USER:-root}"

cd /usr/src/incubator-pagespeed-mod

# /usr/src is bind-mounted from the host; git refuses to operate on a
# tree owned by a different uid without this opt-in.
git config --global --add safe.directory '*'

# install/build_env.sh dispatches on `lsb_release -is`. Debian ships only
# install/debian/ packaging files — no build_env.sh / install_required_packages.sh.
# Drop in the ubuntu helpers (generic enough) so the dispatcher works.
if [ "$DISTRO" = "debian" ]; then
    for f in install/ubuntu/*.sh install/ubuntu/*.mk; do
        [ -e "$f" ] || continue
        cp -f "$f" install/debian/
    done
fi

# Override the upstream install_required_packages.sh with our modernised
# list (no gcc-mozilla, no openjdk-7, no language-pack-tr-base, modern
# Redis). The Dockerfile already pre-installed everything; this just
# makes build_psol.sh's call a no-op instead of trying to install dead
# packages.
target_dir="install/${DISTRO}"
[ -d "$target_dir" ] || target_dir="install/ubuntu"
cp -f /modern-install_required_packages.sh "${target_dir}/install_required_packages.sh"
chmod +x "${target_dir}/install_required_packages.sh"

# Remove output from any prior compile. The src/ tree is host-mounted
# and shared across dist builds, so without this each later dist would
# just repackage the previous dist's binaries. ccache absorbs the cost
# of recompiling the same source with a different gcc/glibc.
rm -rf psol out/ pagespeed/automatic/pagespeed_automatic.a* psol-*.tar.gz

# Newer glibc removed sys_siglist / pthread_mutex_consistent_np /
# HAVE_PTHREAD_YIELD. These seds are idempotent — safe to apply
# unconditionally regardless of dist.
sed -i -r 's/sys_siglist\[signum\]/strsignal(signum)/g' \
    third_party/apr/src/threadproc/unix/signals.c
sed -i s/"pthread_mutex_consistent_np"/"pthread_mutex_consistent"/g \
    third_party/apr/src/locks/unix/proc_mutex.c
sed -i s/"define HAVE_PTHREAD_YIELD 1"/"define HAVE_PTHREAD_YIELD 0"/g \
    third_party/apr/gen/arch/linux/x64/include/apr_private.h

# gcc-12+ defaults to stricter C standards and turns common chromium-era
# warnings into errors. Disarm them so the pinned source still compiles.
RELAX_C="-std=gnu17 -Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types -Wno-error=int-conversion -Wno-error=implicit-int"
RELAX_CXX="-std=gnu++17 -Wno-error=narrowing -Wno-error=register -Wno-error=deprecated-declarations"

# Runtime-performance flags for the static psol library. psol is linked
# into ngx_pagespeed.so on potentially-different deploy hosts, so we
# pick a portable baseline ISA (x86-64-v2 = Sandy Bridge+, covers
# anything realistic) and leave LTO off — pagespeed_automatic.a is
# built by ar-merging dozens of partial archives, exactly the case
# where chromium-era gyp + LTO breaks.
PERF_FLAGS="-O3 -march=x86-64-v2 -mtune=generic -fno-semantic-interposition -fno-plt -DNDEBUG"

export CFLAGS="${CFLAGS:-} ${RELAX_C} ${PERF_FLAGS}"
export CXXFLAGS="${CXXFLAGS:-} ${RELAX_CXX} ${PERF_FLAGS}"

# Force gyp/make to invoke the compiler via the ccache shim path. Setting
# CC/CXX to the shim directly (not `ccache gcc`) avoids accidental double-
# wrapping when sub-makes also have /usr/lib/ccache on PATH.
export CC="/usr/lib/ccache/gcc"
export CXX="/usr/lib/ccache/g++"

# Finally! build psol! Get some coffee and let the magic do it's job
python build/gyp_chromium --depth=.
install/build_psol.sh --skip_tests

# build_psol.sh produces psol-<version>-x64.tar.gz and then removes the
# psol/ working dir. Extract, strip debug, repack as xz.
gz_tarball=$(ls -t psol-*.tar.gz 2>/dev/null | head -1)
if [ -z "$gz_tarball" ] || [ ! -f "$gz_tarball" ]; then
    echo "ERROR: no psol-*.tar.gz produced — build_psol.sh failed." >&2
    exit 1
fi

echo "Repacking ${gz_tarball} → psol-${DIST}.tar.xz (-9 -T${NUMCORE})"
tmpdir=$(mktemp -d)
tar -xzf "$gz_tarball" -C "$tmpdir"

# Strip debug info from psol's static archives. The final ngx_pagespeed.so
# is stripped again by dh_strip downstream, so this only shrinks the
# tarball + speeds up the nginx link — runtime size unchanged.
if command -v strip >/dev/null 2>&1; then
    size_before=$(du -sh "$tmpdir/psol" | cut -f1)
    find "$tmpdir/psol" -type f \( -name '*.a' -o -name '*.o' -o -name '*.so' -o -name '*.so.*' \) -print0 |
        xargs -0 -r -P "${NUMCORE}" -n 1 strip --strip-debug --strip-unneeded 2>/dev/null || true
    size_after=$(du -sh "$tmpdir/psol" | cut -f1)
    echo "Stripped psol/: ${size_before} → ${size_after}"
fi

( cd "$tmpdir" && XZ_OPT="-9 -T${NUMCORE}" tar cJf "/usr/src/psol-${DIST}.tar.xz" psol/ )
rm -rf "$tmpdir"

TIME_ENDED="`date`"

echo "ccache stats after build:"
ccache -s | sed 's/^/  /'

echo "Finished!"
echo "Started: ${TIME_STARTED}"
echo "Ended:   ${TIME_ENDED}"
echo "Cores:   ${NUMCORE}"
echo "Dumped psol.tar.xz as /usr/src/psol-${DIST}.tar.xz"
echo "--------------------------------------------------> The End"
