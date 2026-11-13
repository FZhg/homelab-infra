# One member of the external etcd cluster, run as a plain systemd service
# (no kubeadm static pods) so you can see and break every moving part.
class profile::etcd {
  $version  = lookup('versions.etcd')
  $nodes    = lookup('nodes')
  $hostname = $facts['networking']['hostname']
  $ip       = $nodes[$hostname]['ip']
  $state    = lookup('etcd_initial_cluster_state')
  $dir      = "/opt/etcd-${version}-linux-amd64"
  $path     = ['/usr/local/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin']

  $members         = $nodes.filter |$name, $n| { $n['role'] == 'etcd' }
  $initial_cluster = $members.map |$name, $n| { "${name}=https://${n['ip']}:2380" }.join(',')
  $endpoints       = $members.map |$name, $n| { "https://${n['ip']}:2379" }.join(',')

  group { 'etcd':
    ensure => present,
    system => true,
  }

  user { 'etcd':
    ensure     => present,
    system     => true,
    gid        => 'etcd',
    home       => '/var/lib/etcd',
    shell      => '/usr/sbin/nologin',
    managehome => false,
    require    => Group['etcd'],
  }

  file { '/var/lib/etcd':
    ensure => directory,
    owner  => 'etcd',
    group  => 'etcd',
    mode   => '0700',
  }

  # Binaries from the official release tarball. Bump versions.etcd to upgrade.
  exec { "install-etcd-${version}":
    command  => "curl -fsSL https://github.com/etcd-io/etcd/releases/download/${version}/etcd-${version}-linux-amd64.tar.gz | tar -xz -C /opt",
    creates  => "${dir}/etcd",
    provider => shell,
    path     => $path,
  }

  ['etcd', 'etcdctl', 'etcdutl'].each |$bin| {
    file { "/usr/local/bin/${bin}":
      ensure  => link,
      target  => "${dir}/${bin}",
      require => Exec["install-etcd-${version}"],
    }
  }

  file { ['/etc/etcd', '/etc/etcd/pki']:
    ensure => directory,
    owner  => 'etcd',
    group  => 'etcd',
    mode   => '0750',
  }

  file { '/etc/etcd/pki/ca.crt':
    ensure  => file,
    mode    => '0644',
    content => lookup('etcd_ca_crt'),
  }

  file { '/etc/etcd/pki/server.crt':
    ensure  => file,
    mode    => '0644',
    content => lookup('etcd_server_crt'),
  }

  file { '/etc/etcd/pki/server.key':
    ensure    => file,
    owner     => 'etcd',
    group     => 'etcd',
    mode      => '0600',
    content   => Sensitive(lookup('etcd_server_key')),
    show_diff => false,
  }

  file { '/etc/systemd/system/etcd.service':
    ensure  => file,
    content => epp('profile/etcd.service.epp', {
      'member_name'     => $hostname,
      'ip'              => $ip,
      'initial_cluster' => $initial_cluster,
      'state'           => $state,
    }),
  }

  exec { 'etcd-daemon-reload':
    command     => 'systemctl daemon-reload',
    refreshonly => true,
    path        => $path,
    subscribe   => File['/etc/systemd/system/etcd.service'],
  }

  service { 'etcd':
    ensure    => running,
    enable    => true,
    require   => [User['etcd'], File['/var/lib/etcd']],
    subscribe => [
      Exec['etcd-daemon-reload'],
      File['/usr/local/bin/etcd'],
      File['/etc/etcd/pki/ca.crt'],
      File['/etc/etcd/pki/server.crt'],
      File['/etc/etcd/pki/server.key'],
    ],
  }

  # `sudo ectl member list -w table` on any etcd node, for experiments.
  file { '/usr/local/sbin/ectl':
    ensure  => file,
    mode    => '0755',
    content => @("EOT"/$),
      #!/bin/sh
      # Managed by Puppet: etcdctl with this cluster's endpoints and certs.
      exec /usr/local/bin/etcdctl --endpoints=${endpoints} \
        --cacert=/etc/etcd/pki/ca.crt --cert=/etc/etcd/pki/server.crt --key=/etc/etcd/pki/server.key "\$@"
      | EOT
  }
}
