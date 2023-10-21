#!/bin/sh

CDIR=$(pwd)
SRCDIR="${CDIR}/src"

NUMCORE=$(cat /proc/cpuinfo | grep -c cores)
export NUMCORE

rm -rf src
mkdir -p src
cd src

if [ ! -d "incubator-pagespeed-mod" ]; then
    git clone -c advice.detachedHead=false --recursive https://github.com/apache/incubator-pagespeed-mod.git
    cd incubator-pagespeed-mod
else
    cd incubator-pagespeed-mod
    git pull --recurse-submodules
fi

# Do a hard reset to the last working commit (before bazel got introduced)
git reset --hard 409bd76

# init and update all submodules (removed after #409bd76)
git submodule update --init --recursive --jobs=${NUMCORE} --force

# Fix conflict with gettid
# based on
# https://github.com/apache/incubator-pagespeed-mod/issues/2040
# https://github.com/tensorflow/tensorflow/issues/33758
sed -i 's/static long gettid/static long sys_gettid/g'  third_party/grpc/src/src/core/lib/support/log_linux.c
sed -i -e 's/tid = gettid()/tid = sys_gettid()/g'  third_party/grpc/src/src/core/lib/support/log_linux.c
sed -i 's/static intptr_t gettid/static intptr_t sys_gettid/g'  third_party/grpc/src/src/core/lib/support/log_posix.c
sed -i -e 's/ gettid()/ sys_gettid()/g'  third_party/grpc/src/src/core/lib/support/log_posix.c

# Apply some handpicked PR's from https://github.com/apache/incubator-pagespeed-mod/
for PR in `ls ${CDIR}/pr`
do
    patch -p1 < ${CDIR}/pr/${PR}
done

# Add more jobs ($NUMCORE) to the make arguments
sed -i s/"MAKE_ARGS=(V=1 BUILDTYPE=\$buildtype)"/"MAKE_ARGS=(V=1 -j${NUMCORE} BUILDTYPE=\$buildtype)"/ install/build_psol.sh

# Fix log output, we run in docker so it should go to STDOUT
sed -i  /"run_with_log log\/install_deps.log"/d install/build_psol.sh
sed -i s/"run_with_log log\/gyp.log"//g            install/build_psol.sh
sed -i s/"run_with_log log\/psol_build.log"//g     install/build_psol.sh
sed -i /"run_with_log \.\.\/\.\.\/log\/psol_automatic_build.log"/d install/build_psol.sh

# Build dockers and build psol from docker/bootstrap.sh
# jammy and higher have to go last, because of the sed for glibc functions in the docker
cd ${CDIR}
for DIST in focal bionic xenial trusty jammy
do
    cp docker/Dockerfile-template docker/Dockerfile
    sed -i s/OS/ubuntu-base/ docker/Dockerfile
    sed -i s/DIST/${DIST}/ docker/Dockerfile
    cd docker
    docker build --no-cache -t eilandert/psol:${DIST} .
    docker run --volume ${SRCDIR}:/usr/src eilandert/psol:${DIST}
    cd ..
done
