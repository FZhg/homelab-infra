# Member of the external etcd cluster used by the Kubernetes API server.
class role::etcd {
  include profile::base
  include profile::etcd
}
