#!/usr/bin/env bash
# Runs once on each VM, from cloud-init.
# Installs the OpenVox agent (community Puppet) and hands the node to the puppet-apply timer.
set -euo pipefail
export HOME=/root DEBIAN_FRONTEND=noninteractive

# shellcheck source=/dev/null
. /etc/os-release

if [ ! -x /opt/puppetlabs/bin/puppet ]; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://apt.voxpupuli.org/openvox-keyring.gpg -o /tmp/openvox-keyring
  if grep -q "BEGIN PGP" /tmp/openvox-keyring; then
    gpg --batch --yes --dearmor -o /etc/apt/keyrings/openvox.gpg /tmp/openvox-keyring
  else
    install -m 0644 /tmp/openvox-keyring /etc/apt/keyrings/openvox.gpg
  fi
  echo "deb [signed-by=/etc/apt/keyrings/openvox.gpg] https://apt.voxpupuli.org ${ID}${VERSION_ID} openvox8" \
    > /etc/apt/sources.list.d/openvox8.list
  apt-get update
  apt-get install -y openvox-agent
  # Masterless: no agent daemon talking to a Puppet server.
  systemctl disable --now puppet.service 2>/dev/null || true
fi

install -m 0644 /opt/infra/scripts/node/puppet-apply.service /etc/systemd/system/puppet-apply.service
install -m 0644 /opt/infra/scripts/node/puppet-apply.timer /etc/systemd/system/puppet-apply.timer
systemctl daemon-reload
systemctl enable --now puppet-apply.timer

# First run now, in the background so cloud-init can finish. Logs: journalctl -u puppet-apply
systemctl start --no-block puppet-apply.service
