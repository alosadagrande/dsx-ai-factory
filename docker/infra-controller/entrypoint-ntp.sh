#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Generates /etc/chrony.conf from environment variables and starts chronyd.
#
# Environment variables:
#   NTP_SERVERS    Comma-separated list of upstream NTP servers.
#                  Default: time1-4.google.com
#   NTP_DIRECTIVES Comma-separated extra chrony.conf directives (e.g. "ratelimit").

set -e

CONF=/etc/chrony.conf

{
  if [ -n "${NTP_SERVERS}" ]; then
    echo "${NTP_SERVERS}" | tr ',' '\n' | while IFS= read -r server; do
      server=$(echo "$server" | tr -d ' ')
      [ -n "$server" ] && echo "server $server iburst"
    done
  else
    echo "server time1.google.com iburst"
    echo "server time2.google.com iburst"
    echo "server time3.google.com iburst"
    echo "server time4.google.com iburst"
  fi

  echo "allow all"
  echo "makestep 1.0 3"
  echo "rtcsync"
  echo "driftfile /var/lib/chrony/drift"
  echo "logdir /var/log/chrony"

  if [ -n "${NTP_DIRECTIVES}" ]; then
    echo "${NTP_DIRECTIVES}" | tr ',' '\n' | while IFS= read -r directive; do
      directive=$(echo "$directive" | sed 's/^[[:space:]]*//')
      [ -n "$directive" ] && echo "$directive"
    done
  fi
} > "${CONF}"

exec /usr/sbin/chronyd -d -f "${CONF}"
