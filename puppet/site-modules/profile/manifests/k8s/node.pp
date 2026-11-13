# Everything a Kubernetes node needs before kubeadm runs:
# kernel settings, containerd 2.x, and pinned kubelet/kubeadm/kubectl.
class profile::k8s::node {
  $version  = lookup('versions.kubernetes')                    # e.g. "1.37.1"
  $minor    = regsubst($version, '^(\d+\.\d+)\..*$', '\1')     # e.g. "1.37"
  $codename = $facts['os']['distro']['codename']               # e.g. "noble"
  $path     = ['/usr/local/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin']

  # --- Kernel prerequisites -------------------------------------------------
  file { '/etc/modules-load.d/k8s.conf':
    ensure  => file,
    content => "overlay\nbr_netfilter\n",
  }

  exec { 'load-k8s-modules':
    command     => 'modprobe overlay && modprobe br_netfilter',
    provider    => shell,
    path        => $path,
    refreshonly => true,
    subscribe   => File['/etc/modules-load.d/k8s.conf'],
  }

  file { '/etc/sysctl.d/99-k8s.conf':
    ensure  => file,
    content => "net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n",
    require => Exec['load-k8s-modules'],
  }

  exec { 'apply-k8s-sysctl':
    command     => 'sysctl --system',
    path        => $path,
    refreshonly => true,
    subscribe   => File['/etc/sysctl.d/99-k8s.conf'],
  }

  exec { 'swapoff':
    command  => 'swapoff -a',
    onlyif   => 'test -n "$(swapon --noheadings)"',
    provider => shell,
    path     => $path,
  }

  # --- APT repositories -----------------------------------------------------
  # containerd 2.x comes from Docker's repo (Kubernetes 1.36+ no longer supports containerd 1.x).
  file { '/etc/apt/keyrings':
    ensure => directory,
    mode   => '0755',
  }

  exec { 'docker-apt-key':
    command     => 'curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg',
    creates     => '/etc/apt/keyrings/docker.gpg',
    provider    => shell,
    environment => ['HOME=/root'],
    path        => $path,
    require     => File['/etc/apt/keyrings'],
  }

  exec { "kubernetes-apt-key-${minor}":
    command     => "curl -fsSL https://pkgs.k8s.io/core:/stable:/v${minor}/deb/Release.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-${minor}.gpg",
    creates     => "/etc/apt/keyrings/kubernetes-${minor}.gpg",
    provider    => shell,
    environment => ['HOME=/root'],
    path        => $path,
    require     => File['/etc/apt/keyrings'],
  }

  file { '/etc/apt/sources.list.d/docker.list':
    ensure  => file,
    content => "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable\n",
    require => Exec['docker-apt-key'],
  }

  # One repo per Kubernetes minor version; bumping versions.kubernetes to a new minor switches it.
  file { '/etc/apt/sources.list.d/kubernetes.list':
    ensure  => file,
    content => "deb [signed-by=/etc/apt/keyrings/kubernetes-${minor}.gpg] https://pkgs.k8s.io/core:/stable:/v${minor}/deb/ /\n",
    require => Exec["kubernetes-apt-key-${minor}"],
  }

  exec { 'apt-update-k8s':
    command     => 'apt-get update',
    path        => $path,
    refreshonly => true,
    subscribe   => [
      File['/etc/apt/sources.list.d/docker.list'],
      File['/etc/apt/sources.list.d/kubernetes.list'],
    ],
  }

  # --- containerd -----------------------------------------------------------
  package { 'containerd.io':
    ensure  => installed,
    require => Exec['apt-update-k8s'],
  }

  file { '/etc/containerd/config.toml':
    ensure  => file,
    source  => 'puppet:///modules/profile/containerd-config.toml',
    require => Package['containerd.io'],
  }

  service { 'containerd':
    ensure    => running,
    enable    => true,
    subscribe => File['/etc/containerd/config.toml'],
  }

  # --- kubelet / kubeadm / kubectl (pinned and held) -------------------------
  package { ['kubelet', 'kubeadm', 'kubectl']:
    ensure  => "${version}-1.1",
    mark    => 'hold',
    require => [Exec['apt-update-k8s'], Service['containerd'], Exec['apply-k8s-sysctl'], Exec['swapoff']],
  }

  # kubeadm starts kubelet; until then it restarts in a loop, which is expected.
  service { 'kubelet':
    enable  => true,
    require => Package['kubelet'],
  }
}
