#!/bin/sh
# Build PSOL (PageSpeed Optimization Library) tarballs for each
# supported distribution. Idempotent: safe to re-run; src/ is reused
# across runs, source-tree fixups are guarded by marker files.

set -e

CDIR=$(pwd)
SRCDIR="${CDIR}/src"
PSMOD="${SRCDIR}/incubator-pagespeed-mod"
# Shared ccache across all dist builds. Lives on the host so it survives
# `--rm`; bind-mounted into every container at the same path so ccache's
# compiler-hash keying transparently partitions entries per dist.
CCACHE_HOST_DIR="${CCACHE_HOST_DIR:-${CDIR}/.ccache}"
mkdir -p "${CCACHE_HOST_DIR}"

NUMCORE=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
export NUMCORE

mkdir -p "${SRCDIR}"
cd "${SRCDIR}"

if [ ! -d "incubator-pagespeed-mod/.git" ]; then
    # Fresh clone. Disable advice noise and use jobs for submodules later.
    git clone -c advice.detachedHead=false \
        https://github.com/apache/incubator-pagespeed-mod.git
fi

cd "${PSMOD}"

# Last known-good commit (before bazel was introduced). Pin hard.
PSMOD_PIN=409bd76
if [ "$(git rev-parse HEAD)" != "$(git rev-parse ${PSMOD_PIN})" ]; then
    git fetch --tags origin
    git reset --hard ${PSMOD_PIN}
    # New pin → invalidate prior source-tree fixups.
    rm -f .fixups-applied
fi

# init and update all submodules (removed after #409bd76).
# Cap at 8 — github sometimes RPC-CANCELs higher-concurrency fetches.
SM_JOBS=$([ "${NUMCORE}" -gt 8 ] && echo 8 || echo "${NUMCORE}")
git submodule update --init --recursive --jobs=${SM_JOBS} --force

# Idempotent source-tree fixups (sed). These must run on every invocation
# because `git submodule update --force` above restores the files.
# Fix conflict with gettid (https://github.com/apache/incubator-pagespeed-mod/issues/2040)
sed -i 's/static long gettid/static long sys_gettid/g' \
    third_party/grpc/src/src/core/lib/support/log_linux.c
sed -i -e 's/\btid = gettid()/tid = sys_gettid()/g' \
    third_party/grpc/src/src/core/lib/support/log_linux.c
sed -i 's/static intptr_t gettid/static intptr_t sys_gettid/g' \
    third_party/grpc/src/src/core/lib/support/log_posix.c
sed -i -e 's/ gettid()/ sys_gettid()/g' \
    third_party/grpc/src/src/core/lib/support/log_posix.c

# Bump parallelism and drop verbose echoing of each compile command
# (cuts log size ~10x; ccache stats still show throughput).
sed -i -E "s/MAKE_ARGS=\(V=[01] BUILDTYPE=\\\$buildtype\)/MAKE_ARGS=(V=0 -j${NUMCORE} BUILDTYPE=\$buildtype)/" install/build_psol.sh

# Fix log output: we run in docker, send everything to STDOUT.
sed -i  /"run_with_log log\/install_deps.log"/d install/build_psol.sh
sed -i s/"run_with_log log\/gyp.log"//g            install/build_psol.sh
sed -i s/"run_with_log log\/psol_build.log"//g     install/build_psol.sh
sed -i /"run_with_log \.\.\/\.\.\/log\/psol_automatic_build.log"/d install/build_psol.sh

# One-shot patches — guarded so re-runs don't double-apply.
if [ ! -f .patches-applied ]; then
    for PR in $(ls "${CDIR}/pr"); do
        patch -p1 < "${CDIR}/pr/${PR}"
    done
    touch .patches-applied
fi

# Build dockers and build psol from docker/bootstrap.sh.
# jammy/trixie (newer glibc) have to go last — their source-tree fixups
# are not backwards-compatible with older glibc builds.
cd "${CDIR}"
: ${DISTS:="bullseye:debian-base bookworm:debian-base jammy:ubuntu-base noble:ubuntu-base resolute:ubuntu-base trixie:debian-base"}

for ENTRY in ${DISTS}
do
    DIST=${ENTRY%%:*}
    OS=${ENTRY##*:}
    cp docker/Dockerfile-template docker/Dockerfile
    sed -i s/OS/${OS}/ docker/Dockerfile
    sed -i s/DIST/${DIST}/ docker/Dockerfile
    cd docker
    # Use docker layer cache. The Dockerfile COPYs bootstrap.sh and the
    # modern-deps script — changes to either correctly invalidate downstream
    # layers; identical builds reuse the cached apt layers.
    docker build -t eilandert/psol:${DIST} .
    docker run --rm \
        --volume ${SRCDIR}:/usr/src \
        --volume ${CCACHE_HOST_DIR}:/ccache \
        --env CCACHE_DIR=/ccache \
        eilandert/psol:${DIST}
    cd ..
done
