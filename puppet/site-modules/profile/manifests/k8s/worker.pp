# Joins the cluster with the pre-shared token and CA hash from OpenBao.
class profile::k8s::worker {
  $nodes    = lookup('nodes')
  $hostname = $facts['networking']['hostname']
  $cp_ip    = $nodes.filter |$name, $n| { $n['role'] == 'k8s_control' }.values[0]['ip']
  $path     = ['/usr/local/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin']

  file { '/etc/homelab':
    ensure => directory,
  }

  file { '/etc/homelab/kubeadm-join.yaml':
    ensure    => file,
    mode      => '0600',
    show_diff => false,
    content   => Sensitive(epp('profile/kubeadm-join.yaml.epp', {
      'hostname' => $hostname,
      'cp_ip'    => $cp_ip,
      'token'    => lookup('join_token'),
      'ca_hash'  => lookup('join_ca_hash'),
    })),
  }

  # Retries while the control plane is still coming up. `kubeadm reset` first
  # clears anything a half-finished earlier attempt left behind.
  exec { 'kubeadm-join':
    command   => 'kubeadm reset -f >/dev/null 2>&1; kubeadm join --config /etc/homelab/kubeadm-join.yaml',
    creates   => '/etc/kubernetes/kubelet.conf',
    provider  => shell,
    path      => $path,
    tries     => 20,
    try_sleep => 30,
    timeout   => 300,
    logoutput => true,
    require   => File['/etc/homelab/kubeadm-join.yaml'],
  }
}
