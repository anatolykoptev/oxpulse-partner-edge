# syntax=docker/dockerfile:1.7
# Fully static musl build of coturn (turnserver + turnutils_uclient) for relay-only
# nodes. Static, so the same file runs on any Debian/Ubuntu regardless of glibc;
# built on Alpine like the official coturn image.
#
#   docker buildx build --target artifacts --output type=local,dest=out \
#       -f relay/coturn-static/Dockerfile relay/coturn-static
#
# Source and hash come from version.env (COTURN_VERSION / COTURN_SHA256): the
# upstream tag tarball is pinned by sha256 and the build fails on a mismatch.
#
# Attack surface: no database drivers (sqlite, postgres, mysql, mongo, redis),
# no libmicrohttpd (so no Prometheus exporter), no systemd, no OAuth token code
# (-DTURN_NO_OAUTH). They are left out by not installing their -dev packages
# (coturn's ./configure auto-detects them) plus TURN_NO_PROMETHEUS / TURN_NO_OAUTH.
# Remaining: libevent + OpenSSL, statically linked.
#
# alpine:3.24 pinned by multi-arch index digest.
ARG ALPINE_IMAGE=alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

FROM ${ALPINE_IMAGE} AS build
ARG COTURN_VERSION
ARG COTURN_SHA256
RUN apk add --no-cache build-base linux-headers curl ca-certificates \
        libevent-dev libevent-static openssl-dev openssl-libs-static zlib-static
WORKDIR /src
RUN curl -fsSL --proto '=https' --tlsv1.2 -o coturn.tgz \
        "https://github.com/coturn/coturn/archive/refs/tags/${COTURN_VERSION}.tar.gz" \
 && echo "${COTURN_SHA256}  coturn.tgz" | sha256sum -c - \
 && tar xzf coturn.tgz --strip-components=1 && rm coturn.tgz
# ./configure takes its link line from `pkg-config --libs`; the static archives
# need the --static variant (libssl.a alone leaves libcrypto symbols undefined).
RUN printf '#!/bin/sh\nexec pkgconf --static "$@"\n' > /usr/local/bin/pkgconf-static \
 && chmod +x /usr/local/bin/pkgconf-static
ENV TURN_NO_PROMETHEUS=1 \
    CFLAGS="-O2 -DTURN_NO_OAUTH -fstack-protector-strong -D_FORTIFY_SOURCE=2" \
    LDFLAGS="-static" \
    PKGCONFIG=/usr/local/bin/pkgconf-static
RUN ./configure --prefix=/usr --disable-rpath \
 && make -j"$(nproc)" bin/turnserver bin/turnutils_uclient bin/turnutils_peer \
 && strip bin/turnserver bin/turnutils_uclient bin/turnutils_peer \
 && for b in turnserver turnutils_uclient turnutils_peer; do \
      ! readelf -d "bin/$b" 2>/dev/null | grep -q NEEDED || { echo "$b is not static"; exit 1; }; \
    done \
 && mkdir /out && cp bin/turnserver bin/turnutils_uclient bin/turnutils_peer /out/ \
 && /out/turnserver --version

FROM scratch AS artifacts
COPY --from=build /out/ /
