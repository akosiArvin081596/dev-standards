# Throwaway test image for the team server scripts (tests/server/run.sh builds it per base image as
# team-srvtest-img-<version>). systemd is installed only for `systemd-analyze`; it never runs as PID 1
# here, so the scripts take their "systemd not running" path. Databases and nginx are started with
# `service … start`.
#   docker build --build-arg BASE=ubuntu:26.04 …
ARG BASE=ubuntu:24.04
FROM ${BASE}

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC \
    LANG=C.UTF-8

# The sudo a fresh server of this release gets: sudo-rs from Ubuntu 25.10 on, classic sudo before.
# php-fpm is the release's default PHP (8.3 on 24.04, 8.5 on 26.04).
RUN . /etc/os-release \
 && sudo_pkg=sudo \
 && if [ "${VERSION_ID%%.*}" -gt 25 ] || [ "$VERSION_ID" = "25.10" ]; then sudo_pkg=sudo-rs; fi \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      nginx postgresql postgresql-client mariadb-server mariadb-client \
      php-fpm "$sudo_pkg" \
      openssl curl jq python3 gzip openssh-client systemd logrotate \
      ca-certificates tzdata procps iproute2 \
 && rm -rf /var/lib/apt/lists/*

CMD ["sleep", "infinity"]
