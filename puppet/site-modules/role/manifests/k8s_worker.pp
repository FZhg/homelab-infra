# A Kubernetes worker node.
class role::k8s_worker {
  include profile::base
  include profile::k8s::node
  include profile::k8s::worker

  Class['profile::k8s::node'] -> Class['profile::k8s::worker']
}
