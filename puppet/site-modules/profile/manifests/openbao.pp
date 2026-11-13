# OpenBao server: one node, integrated Raft storage, TLS from the homelab CA.
# The TLS cert/key arrive through cloud-init in /etc/openbao-bootstrap/.
# Initialising and unsealing happen from your workstation: `make openbao-init`.
class profile::openbao {
  $version  = lookup('versions.openbao')
  $hostname = $facts['networking']['hostname']
  $ip       = lookup('nodes')[$hostname]['ip']
  $deb      = "/var/cache/openbao_${version}_linux_amd64.deb"
  $path     = ['/usr/local/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin']

  exec { "download-openbao-${version}":
    command => "curl -fsSL -o ${deb} https://github.com/openbao/openbao/releases/download/v${version}/openbao_${version}_linux_amd64.deb",
    creates => $deb,
    path    => $path,
  }

  # Installs or upgrades whenever versions.openbao in inventory.yaml changes.
  exec { "install-openbao-${version}":
    command     => "apt-get install -y -o Dpkg::Options::=--force-confold ${deb}",
    unless      => "bao version 2>/dev/null | grep -q 'v${version}'",
    provider    => shell, # `bao` doesn't exist before the first install
    environment => ['DEBIAN_FRONTEND=noninteractive'],
    path        => $path,
    require     => Exec["download-openbao-${version}"],
  }

  file { ['/opt/openbao', '/opt/openbao/data']:
    ensure  => directory,
    owner   => 'openbao',
    group   => 'openbao',
    mode    => '0700',
    require => Exec["install-openbao-${version}"],
  }

  file { '/etc/openbao':
    ensure  => directory,
    require => Exec["install-openbao-${version}"],
  }

  file { '/etc/openbao/tls':
    ensure => directory,
    owner  => 'root',
    group  => 'openbao',
    mode   => '0750',
  }

  file { '/etc/openbao/tls/tls.crt':
    ensure => file,
    source => '/etc/openbao-bootstrap/tls.crt',
    mode   => '0644',
  }

  file { '/etc/openbao/tls/tls.key':
    ensure    => file,
    source    => '/etc/openbao-bootstrap/tls.key',
    owner     => 'root',
    group     => 'openbao',
    mode      => '0640',
    show_diff => false,
  }

  file { '/etc/openbao/openbao.hcl':
    ensure  => file,
    owner   => 'root',
    group   => 'openbao',
    mode    => '0640',
    content => epp('profile/openbao.hcl.epp', { 'ip' => $ip, 'hostname' => $hostname }),
  }

  # The package ships openbao.service (bao server -config=/etc/openbao/openbao.hcl).
  service { 'openbao':
    ensure    => running,
    enable    => true,
    require   => File['/opt/openbao/data'],
    subscribe => [
      Exec["install-openbao-${version}"],
      File['/etc/openbao/openbao.hcl'],
      File['/etc/openbao/tls/tls.crt'],
      File['/etc/openbao/tls/tls.key'],
    ],
  }
}
