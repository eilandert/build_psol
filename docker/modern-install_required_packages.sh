#!/bin/bash
#
# Modernised replacement for install/<distro>/install_required_packages.sh
# Used for any reasonably-recent dist (jammy+, bullseye+) — no gcc-mozilla,
# no openjdk-7, no language-pack-tr-base, no Redis-from-source. The system
# gcc + the CFLAGS escape hatches in bootstrap.sh handle the pinned-409bd76
# tree on modern compilers.
#

set -e

if [ "$UID" -ne 0 ]; then
  echo Root is required to run this. Re-execing with sudo
  exec sudo "$0" "$@"
  exit 1  # NOTREACHED
fi

# We accept --additional_dev_packages from build_psol.sh and silently
# ignore it — we always install the same set on trixie.
if [ "${1:-}" = "--additional_dev_packages" ]; then
  shift
fi

if [ $# -ne 0 ]; then
  echo "Usage: $(basename "$0") [--additional_dev_packages]" >&2
  exit 1
fi

binary_packages=(
  # Core build chain
  build-essential g++ gperf
  # Source-package tooling
  subversion devscripts fakeroot git
  # Libraries pagespeed links against
  zlib1g-dev libexpat1-dev libev-dev libssl-dev
  uuid-dev pkg-config
  # Misc utilities used by build scripts
  wget curl net-tools rsync psmisc
  autoconf libtool-bin
)
# NOTE: upstream's list also includes libpcre3-dev, but pagespeed only
# uses pcre for its --skip_tests test runner. Resolute (Ubuntu 25.10)
# dropped libpcre3-dev entirely, so we omit it.
# NOTE: we intentionally omit apache2 / ssl-cert / memcached / redis /
# valgrind / default-jre-headless. The upstream list pulls these in for
# `make test`, which we always run with --skip_tests. Avoids dragging in
# myguard.nl-rebuilt apache2 with broken libssl3 deps on jammy.

apt-get -y -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" install "${binary_packages[@]}"
