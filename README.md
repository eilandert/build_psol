# build_psol — Build PageSpeed Optimization Library (PSOL) Binaries with Docker

> ⚠️ **End of life.** Apache abandoned `incubator-pagespeed-mod`. Our final
> contribution to this project is dated **2026-05-24**. We will leave the
> repository up so existing installs can still rebuild PSOL on modern
> distributions, but no further development is planned. If you are
> evaluating PageSpeed for a new deployment, **don't** — see
> [the alternatives](#what-to-use-instead) below.

`build_psol` produces statically-linked `psol-<dist>.tar.xz` archives — the
PageSpeed Optimization Library that `ngx_pagespeed` (and `mod_pagespeed`)
links against. We run each build inside a Docker container per target
distribution, so the resulting binary is glibc-correct for that release.

Tarballs in this repo are built from
[`apache/incubator-pagespeed-mod`](https://github.com/apache/incubator-pagespeed-mod)
pinned to commit `409bd76` (the last known-good revision before Bazel
broke the tree), with patches applied to make it compile on modern
glibc and gcc.

## Pre-built binaries

The `binaries/` directory ships ready-to-use PSOL tarballs for:

| Family | Codename | Status |
|---|---|---|
| Debian 11 | `bullseye` | ✅ |
| Debian 12 | `bookworm` | ✅ |
| Debian 13 | `trixie` | ✅ |
| Ubuntu 22.04 LTS | `jammy` | ✅ |
| Ubuntu 24.04 LTS | `noble` | ✅ |
| Ubuntu 26.04 LTS | `resolute` | ✅ |
| Ubuntu 18.04 | `bionic` | legacy (no rebuild planned) |
| Ubuntu 20.04 | `focal` | legacy (no rebuild planned) |
| Ubuntu 16.04 | `xenial` | legacy (no rebuild planned) |
| Ubuntu 14.04 | `trusty` | legacy (no rebuild planned) |

Each tarball expands to a `psol/` directory containing
`pagespeed_automatic.a` (the static archive) plus the include headers
that `ngx_pagespeed`'s configure step needs.

## Building from source

```sh
git clone https://github.com/eilandert/build_psol
cd build_psol
./build.sh
```

The default `DISTS` list builds all six modern targets. To rebuild only
one or two:

```sh
DISTS="trixie:debian-base bookworm:debian-base" ./build.sh
```

`build.sh` is idempotent — re-running it reuses the cloned source tree
under `src/`, the shared `ccache` under `.ccache/`, and the docker
layer cache. Each container build invokes `gyp_chromium` and
`install/build_psol.sh`, strips debug symbols, and repacks the result
as `psol-<dist>.tar.xz`.

### Requirements on the build host

- Docker
- About 30 GB of disk (source tree + ccache + per-dist intermediates)
- A reasonably modern CPU — the resulting binaries are tuned for the
  `x86-64-v2` baseline (Sandy Bridge / 2011 and later)

### What's in the Docker images

Each per-dist image is based on
[`eilandert/ubuntu-base`](https://hub.docker.com/r/eilandert/ubuntu-base)
or [`eilandert/debian-base`](https://hub.docker.com/r/eilandert/debian-base).
At image build time we install build-essential, ccache, eatmydata, and
a curated dependency set. At container run time `bootstrap.sh` handles
dist-specific tweaks (Python 2 from the bullseye archive on dists that
removed it, glibc fixups for `sys_siglist` and friends, gcc-12+ flag
relaxations).

## Why is PageSpeed dead?

The short version:

- **Google stepped back.** Apache adopted the project as an incubator,
  but no new code lands and the security backlog is open-ended.

The full story, including a pre-mortem and what we tried, is here:

- [Google PageSpeed For NGINX: What It Was, Why It Died &amp; What To Use Instead](https://deb.myguard.nl/2026/05/google-pagespeed-nginx-what-it-was-alternatives/)
- Original upstream thread:
  [apache/incubator-pagespeed-ngx#1760](https://github.com/apache/incubator-pagespeed-ngx/issues/1760#issuecomment-1358070522)

## What to use instead

PageSpeed bundled compression, image optimisation, minification, and
caching into one module. Modern stacks pull those apart and each piece
is now done better by something else:

- **Compression** — Use [zstd](https://deb.myguard.nl/2026/05/zstd-nginx-module-what-it-does-bugs-fixed/)
  or Brotli at the NGINX layer. Both ship as
  [dynamic modules in our packages](https://deb.myguard.nl/nginx-modules/).
- **Image optimisation** — Optimise at upload time, not at request
  time. Squoosh, ImageMagick, `cwebp`/`avifenc`, or a CDN with image
  transforms (Cloudflare Images, Bunny.net Optimizer). For WordPress:
  EWWW Image Optimizer, ShortPixel.
- **Minification** — Build-time tooling (Vite, esbuild, Webpack) for
  any code you control. For CMS-driven sites where you don't control
  the build, let your CDN do edge-side minify.
- **Page caching** — NGINX FastCGI / proxy cache. Simpler, more
  predictable, and dramatically faster than PageSpeed's on-disk cache.
  See the [NGINX performance guide](https://deb.myguard.nl/2026/05/nginx-angie-the-expert-guide-to-maximum-performance-and-security/).
- **Everything at once** — Put Cloudflare (or another CDN) in front
  of your site. PageSpeed was a single-server CDN emulator; using an
  actual CDN is the modern answer.

## Documentation mirror

The official `modpagespeed.com` documentation is gone. A mirror lives at
[pagespeed.myguard.nl](https://pagespeed.myguard.nl/) — refer to that
for filter configuration and directive reference.

## Project links

- **This builder**: [github.com/eilandert/build_psol](https://github.com/eilandert/build_psol)
- **Our NGINX/Angie packages**: [deb.myguard.nl/nginx-modules/](https://deb.myguard.nl/nginx-modules/)
- **PageSpeed end-of-life writeup**: [PageSpeed for NGINX — what it was, why it died, what to use instead](https://deb.myguard.nl/2026/05/google-pagespeed-nginx-what-it-was-alternatives/)
- **Docs mirror**: [pagespeed.myguard.nl](https://pagespeed.myguard.nl/)
- **Upstream (archived)**: [apache/incubator-pagespeed-mod](https://github.com/apache/incubator-pagespeed-mod)

## License

Build scripts: same Apache-2.0 license as the upstream PageSpeed
project. Pre-built PSOL binaries are derivative works of
`incubator-pagespeed-mod` and carry its Apache-2.0 license.
