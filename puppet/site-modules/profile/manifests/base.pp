# Applied to every node.
class profile::base {
  $domain = lookup('network.domain')
  $nodes  = lookup('nodes')

  # Every node can reach every other node by name, no DNS server needed.
  file { '/etc/hosts':
    ensure  => file,
    mode    => '0644',
    content => epp('profile/hosts.epp', { 'nodes' => $nodes, 'domain' => $domain }),
  }

  package { ['vim', 'htop']:
    ensure => installed,
  }
}
