# The (single) Kubernetes control-plane node.
class role::k8s_control {
  include profile::base
  include profile::k8s::node
  include profile::k8s::control_plane

  Class['profile::k8s::node'] -> Class['profile::k8s::control_plane']
}
