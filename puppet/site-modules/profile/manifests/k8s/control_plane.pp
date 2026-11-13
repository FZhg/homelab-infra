# Single control-plane node using the external etcd cluster.
# The cluster CA and join token are pre-generated (scripts/pki.sh) and come from OpenBao,
# so workers can join without anyone copying a `kubeadm join` command around.
class profile::k8s::control_plane {
  $version  = lookup('versions.kubernetes')
  $nodes    = lookup('nodes')
  $domain   = lookup('network.domain')
  $hostname = $facts['networking']['hostname']
  $ip       = $nodes[$hostname]['ip']
  $token    = lookup('join_token')
  $path     = ['/usr/local/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin']

  $etcd_endpoints = $nodes.filter |$name, $n| { $n['role'] == 'etcd' }.map |$name, $n| { "https://${n['ip']}:2379" }

  # --- Certificates kubeadm should use instead of generating its own --------
  file { ['/etc/kubernetes', '/etc/kubernetes/pki', '/etc/kubernetes/pki/etcd', '/etc/homelab']:
    ensure => directory,
  }

  file { '/etc/kubernetes/pki/ca.crt':
    ensure  => file,
    mode    => '0644',
    content => lookup('k8s_ca_crt'),
  }

  file { '/etc/kubernetes/pki/ca.key':
    ensure    => file,
    mode      => '0600',
    content   => Sensitive(lookup('k8s_ca_key')),
    show_diff => false,
  }

  file { '/etc/kubernetes/pki/etcd/ca.crt':
    ensure  => file,
    mode    => '0644',
    content => lookup('etcd_ca_crt'),
  }

  file { '/etc/kubernetes/pki/apiserver-etcd-client.crt':
    ensure  => file,
    mode    => '0644',
    content => lookup('etcd_client_crt'),
  }

  file { '/etc/kubernetes/pki/apiserver-etcd-client.key':
    ensure    => file,
    mode      => '0600',
    content   => Sensitive(lookup('etcd_client_key')),
    show_diff => false,
  }

  file { '/etc/homelab/kubeadm-init.yaml':
    ensure    => file,
    mode      => '0600',
    show_diff => false,
    content   => Sensitive(epp('profile/kubeadm-init.yaml.epp', {
      'version'        => $version,
      'hostname'       => $hostname,
      'domain'         => $domain,
      'ip'             => $ip,
      'token'          => $token,
      'pod_subnet'     => lookup('k8s_pod_subnet'),
      'service_subnet' => lookup('k8s_service_subnet'),
      'etcd_endpoints' => $etcd_endpoints,
    })),
  }

  # --- Wait for etcd quorum, then kubeadm init (once) ------------------------
  $etcd_curl = 'curl -sf --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/apiserver-etcd-client.crt --key /etc/kubernetes/pki/apiserver-etcd-client.key'

  exec { 'wait-for-etcd':
    command   => "${etcd_curl} ${etcd_endpoints[0]}/health | grep -q '\"health\":\"true\"'",
    unless    => 'test -f /etc/kubernetes/admin.conf',
    provider  => shell,
    path      => $path,
    tries     => 30,
    try_sleep => 10,
    require   => [
      File['/etc/kubernetes/pki/etcd/ca.crt'],
      File['/etc/kubernetes/pki/apiserver-etcd-client.crt'],
      File['/etc/kubernetes/pki/apiserver-etcd-client.key'],
    ],
  }

  exec { 'kubeadm-init':
    command   => 'kubeadm init --config /etc/homelab/kubeadm-init.yaml',
    creates   => '/etc/kubernetes/admin.conf',
    path      => $path,
    timeout   => 900,
    logoutput => true,
    require   => [
      Exec['wait-for-etcd'],
      File['/etc/homelab/kubeadm-init.yaml'],
      File['/etc/kubernetes/pki/ca.crt'],
      File['/etc/kubernetes/pki/ca.key'],
    ],
  }

  # --- Keep the pre-shared join token alive so workers can (re)join any time ---
  exec { 'refresh-join-token':
    command     => "kubeadm token create ${token} --ttl 24h",
    unless      => "kubeadm token list 2>/dev/null | awk '{print \$1}' | grep -qx '${token}'",
    environment => ['KUBECONFIG=/etc/kubernetes/admin.conf'],
    provider    => shell,
    path        => $path,
    require     => Exec['kubeadm-init'],
  }
}
