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
cd ${CDIR}
for DIST in trusty xenial bionic focal jammy
do
    cp docker/Dockerfile-template docker/Dockerfile
    sed -i s/OS/ubuntu-base/ docker/Dockerfile
    sed -i s/DIST/${DIST}/ docker/Dockerfile
    cd docker
    docker build --no-cache -t eilandert/psol:${DIST} .
    docker run --volume ${SRCDIR}:/usr/src eilandert/psol:${DIST}
    cd ..
done
