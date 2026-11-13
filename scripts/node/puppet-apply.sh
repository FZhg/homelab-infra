#!/usr/bin/env bash
# Pull the repo, refresh secrets from OpenBao, then `puppet apply`.
# Run by puppet-apply.timer every 15 minutes, or by hand: sudo systemctl start puppet-apply
set -euo pipefail

exec 9>/run/puppet-apply.lock
flock -n 9 || { echo "puppet-apply already running"; exit 0; }

REPO=/opt/infra
cd "$REPO"
git pull --ff-only --quiet || echo "WARN: git pull failed; applying the current checkout"

if [ -f /etc/homelab/openbao.env ]; then
  "$REPO/scripts/node/fetch-secrets.sh" ||
    echo "WARN: could not refresh secrets from OpenBao (sealed?); using the cached copy"
fi

rc=0
/opt/puppetlabs/bin/puppet apply \
  --detailed-exitcodes \
  --modulepath="$REPO/puppet/site-modules" \
  --hiera_config="$REPO/puppet/hiera.yaml" \
  "$REPO/puppet/manifests/site.pp" || rc=$?

# 0 = no changes, 2 = changes applied; anything else is a failure.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
  echo "puppet apply failed (exit $rc)"
  exit "$rc"
fi
