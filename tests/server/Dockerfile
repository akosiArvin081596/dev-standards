# Throwaway test image for the team server scripts (tests/server/run.sh builds it as team-srvtest-img).
# systemd is installed only for `systemd-analyze`; it never runs as PID 1 here, so the scripts take
# their "systemd not running" path. Databases and nginx are started with `service … start`.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC \
    LANG=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      nginx postgresql postgresql-client mariadb-server mariadb-client \
      php8.3-fpm \
      openssl curl jq python3 gzip sudo openssh-client systemd logrotate \
      ca-certificates tzdata procps iproute2 \
 && rm -rf /var/lib/apt/lists/*

CMD ["sleep", "infinity"]
