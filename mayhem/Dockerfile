# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — RELIC on top of the org C/C++ base image.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t mytag .
FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV — an
# empty value breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
# Undefaulted so the base ENV (ASan+UBSan, halting) flows through unless overridden.
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# Extra apt packages + PRE-FETCHED third-party sources for the cryptofuzz-relic target, so
# mayhem/build.sh re-runs fully OFFLINE:
#   * Botan 3.8.1 (tag)                — the cryptofuzz differential oracle (built by build.sh)
#   * cryptofuzz @ 75e52bea (pinned)   — the OSS-Fuzz harness driving RELIC
#   * Boost 1.84.0 headers             — cryptofuzz build dependency (header-only use)
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
        bzip2 libtool wget ca-certificates \
 && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /deps && cd /deps \
 && git clone --depth 1 --branch 3.8.1 https://github.com/randombit/botan.git \
 && git clone https://github.com/MozillaSecurity/cryptofuzz.git \
 && git -C cryptofuzz checkout 75e52bea13eefd6fee276468a92ae7e47f1f209a \
 && wget -q https://archives.boost.io/release/1.84.0/source/boost_1_84_0.tar.bz2 \
 && tar jxf boost_1_84_0.tar.bz2 && rm boost_1_84_0.tar.bz2 \
 && ( cd boost_1_84_0 && ./bootstrap.sh && ./b2 headers ) \
 && cp -R boost_1_84_0/boost/ /usr/include/ \
 && chown -R 2000:2000 /deps
USER mayhem

WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run the upstream test suite at build time — a failing suite fails the image build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
