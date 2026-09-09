# syntax=docker/dockerfile:1.7

# Both stages use the same pinned base image. Dependabot keeps the digest
# fresh weekly via .github/dependabot.yml.
FROM python:3.14-slim@sha256:cad9a2c871761c413caa6fdd6441c783451e740a48aaeba60ae62a8b53525ef6 AS builder

WORKDIR /build

# Install all transitive deps from the hash-pinned lockfile FIRST. This layer
# caches independently of source changes and is byte-reproducible across
# rebuilds. --require-hashes refuses any package whose sha256 isn't in the
# lockfile. Regenerate with:
#   uv pip compile pyproject.toml -o requirements.lock --generate-hashes
COPY requirements.lock .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --prefix=/install --require-hashes -r requirements.lock

# Now install the package itself without re-resolving deps (they're locked).
COPY pyproject.toml README.md ./
COPY src/ src/
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --prefix=/install --no-deps .

FROM python:3.14-slim@sha256:cad9a2c871761c413caa6fdd6441c783451e740a48aaeba60ae62a8b53525ef6

# Apply Debian security patches on top of the pinned base. Keeps the digest
# pin for reproducibility while picking up CVE fixes between base rebuilds.
#
# The ADD must stay directly above the RUN, or the sentence above stops being
# true. CI builds with a gha cache and this RUN's cache key is only its command
# string, which never changes, so buildkit served the layer from cache forever
# and "CVE fixes between base rebuilds" meant whatever was current the day it
# was first built. On 2026-08-26 that had the Trivy gate failing every PR here
# on libssl3t64 CVE-2026-14456 while trixie-security had carried the fixed
# 3.5.7-1~deb13u2 for some time.
#
# trixie-security's Release file changes when and only when a security update
# is published, so the layer rebuilds exactly when there is something new to
# install and stays cached otherwise.
ADD https://deb.debian.org/debian-security/dists/trixie-security/Release /tmp/debian-security-release
RUN apt-get update && apt-get -y upgrade \
    && rm -rf /tmp/debian-security-release /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /install /usr/local

# Drop pip from the runtime image. Nothing at runtime uses it: dependencies are
# copied into /usr/local from the builder stage, already installed.
#
# This is also the only fix for two recurring Trivy HIGHs. pip ships a vendored
# dependency set (see pip/_vendor/vendor.txt) that Trivy scans as real packages:
# msgpack 1.1.2 (GHSA-6v7p-g79w-8964) and setuptools 70.3.0 (CVE-2025-47273).
# Neither is an application dependency, so no lockfile change can move them, and
# no pip release ships fixed versions. Removing the unused component is the fix.
RUN python -m pip uninstall -y pip \
    && rm -rf /usr/local/lib/python3.*/site-packages/pip \
              /usr/local/lib/python3.*/site-packages/pip-*.dist-info \
              /usr/local/bin/pip /usr/local/bin/pip3 /usr/local/bin/pip3.*

# Pin UID so bind-mounts (if ever used) match host ownership predictably.
RUN useradd --create-home --uid 1000 --shell /bin/bash tracker \
    && mkdir -p /data && chown tracker:tracker /data
USER tracker

VOLUME /data

ENV TRACKER_DB=/data/tracker.db \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# HEALTHCHECK is intentionally NOT defined here. It only makes sense for
# the long-running web service; CLI runs (fetch, dashboard, summary, etc.)
# would fail it. Healthcheck lives in docker-compose.yml on the web service.

ENTRYPOINT ["tracker"]
CMD ["fetch"]
