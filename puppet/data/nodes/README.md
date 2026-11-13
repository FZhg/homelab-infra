# Per-node Hiera overrides

Files here are named after the VM's hostname and win over `inventory.yaml` and `common.yaml`.

Example, `etcd2.yaml`, used when rejoining a replaced etcd member:

```yaml
---
etcd_initial_cluster_state: "existing"
```
