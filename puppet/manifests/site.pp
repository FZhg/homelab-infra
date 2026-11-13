# Every node gets exactly one role, set by cloud-init in
# /etc/puppetlabs/facter/facts.d/role.txt (from inventory.yaml).
node default {
  if $facts['role'] == undef {
    fail('No "role" fact. Check /etc/puppetlabs/facter/facts.d/role.txt')
  }
  include "role::${facts['role']}"
}
