# homelab-infra

One repo that turns a bare Proxmox host into a Kubernetes cluster with an external etcd cluster, using
OpenTofu → cloud-init → OpenVox (Puppet) → kubeadm → Argo CD, with secrets kept in OpenBao.

```
Proxmox host (64 GB / 1 TB)
├── openbao        1 vCPU   1 GB   secrets for everything below
├── etcd1..3       2 vCPU   2 GB   external etcd cluster (systemd, not static pods)
├── cp1            2 vCPU   4 GB   Kubernetes control plane
└── worker1..3     4 vCPU  12 GB   Kubernetes workers
```

## How the pieces fit

| Layer | Tool | Lives in | Owns |
|---|---|---|---|
| VMs | OpenTofu + `bpg/proxmox` | `terraform/` | VM size, disk, IP, first-boot cloud-init |
| First boot | cloud-init | `terraform/cloud-init.yaml.tftpl` | user, role fact, CA cert, clone repo, install OpenVox |
| OS config | OpenVox, masterless `puppet apply` | `puppet/` | packages, etcd, containerd, kubeadm |
| Secrets | OpenBao | `scripts/openbao.sh` | certs, join token, app secrets |
| Workloads | Argo CD + External Secrets Operator | `k8s/` | everything inside the cluster |

`inventory.yaml` is the single source of truth: OpenTofu reads it with `yamldecode`, and Hiera reads the same
file as a data layer, so IPs and versions are written once.

Nothing secret is in git. `scripts/pki.sh` generates certs into `.local/` (gitignored), `make openbao-init`
loads them into OpenBao, and each VM logs in with an AppRole limited to its own IPs and its role's paths.

```
inventory.yaml                 nodes, IPs, sizes, versions
Makefile                       make up = every phase below, in order
terraform/                     VMs + cloud-init snippets
puppet/
  hiera.yaml                   secrets.json > nodes/<host> > inventory.yaml > common.yaml
  manifests/site.pp            include role::<role fact>
  site-modules/role/           openbao, etcd, k8s_control, k8s_worker
  site-modules/profile/        base, openbao, etcd, k8s::{node,control_plane,worker}
scripts/
  pki.sh                       CAs, certs, kubeadm token (workstation)
  openbao.sh                   init / unseal / seed / k8s-auth (workstation)
  node/                        bootstrap, puppet-apply timer, fetch-secrets (run on VMs)
k8s/
  bootstrap/                   Argo CD install + root app (applied once by make)
  apps/                        Applications Argo CD syncs (argocd, external-secrets, platform)
  platform/                    ClusterSecretStore, RBAC, demo ExternalSecret
```

## 1. Prepare Proxmox (once)

Run these in the Proxmox shell (web UI → your node → Shell).

```bash
# Let the "local" storage hold cloud-init snippets and imported cloud images.
pvesm set local --content iso,vztmpl,backup,snippets,import

# An API user + token for OpenTofu. Administrator is a homelab shortcut; narrow it later.
pveum user add tofu@pve
pveum aclmod / -user tofu@pve -role Administrator
pveum user token add tofu@pve homelab --privsep 0     # copy the printed value
```

The `import` content type needs Proxmox VE 8.4 or newer. On older versions, upgrade first.

From your workstation, let OpenTofu SSH to the host as root. It uploads the cloud-init snippets that way.

```bash
ssh-copy-id root@<proxmox-ip>
ssh-add            # the provider uses your ssh-agent
```

## 2. Prepare your workstation

Install: `tofu`, `kubectl`, `helm`, `bao` (OpenBao CLI), `yq` (mikefarah v4), `jq`, `openssl`, `git`, `curl`,
GNU Make 4 or newer, and `etcdctl` for the etcd experiments. macOS `/usr/bin/make` is 3.81 and cannot run
this Makefile; `brew install make` provides `gmake`.

```bash
export PROXMOX_VE_API_TOKEN='tofu@pve!homelab=<uuid-from-step-1>'
```

## 3. Configure

1. Push this repo to GitHub (or your own Gitea). VMs and Argo CD clone it over HTTPS, so make it **public**,
   or see "Private repo" below. No secrets are in it.
2. Edit `inventory.yaml`: every `CHANGE ME`, your SSH public key, and free IPs outside your DHCP range.
3. Replace `YOU/homelab-infra` with your repo in `inventory.yaml`, `k8s/bootstrap/root-app.yaml` and
   `k8s/apps/*.yaml` (`grep -rn YOU/ .`).
4. Set OpenBao's IP in `k8s/platform/external-secrets/cluster-secret-store.yaml`.
5. Commit and push. Nodes run whatever is on the branch, not your local copy.

`make check` refuses to start until steps 2–4 are done.

## 4. Bootstrap

```bash
make up
```

That runs these phases. Each is idempotent, so if one fails, fix it and run that target again.

| Phase | Target | What happens |
|---|---|---|
| 0 | `make pki` | CAs, etcd/OpenBao certs, kubeadm token and CA hash in `.local/pki` |
| 1 | `make openbao` | Downloads the Ubuntu 24.04 image, creates the OpenBao VM. Puppet installs and starts OpenBao |
| 2 | `make openbao-init` | Init (unseal key + root token → `.local/openbao-init.json`), unseal, load secrets, create AppRoles → `.local/approle.json` |
| 3 | `make cluster` | Creates etcd1-3, cp1, worker1-3. Each VM fetches its secrets, Puppet builds etcd, runs `kubeadm init`, workers join |
| 4 | `make kubeconfig` | Waits for `kubeadm init`, copies `admin.conf` to `.local/kubeconfig` |
| 5 | `make cni` | Installs Cilium, waits until every node is Ready |
| 6 | `make argocd` | Installs Argo CD and the root app. From here, git is the source of truth for the cluster |
| 7 | `make openbao-k8s-auth` | Lets External Secrets Operator log in to OpenBao with its service account |

**After phase 2, copy the unseal key and root token from `.local/openbao-init.json` into your password
manager.** Once the lab works you can delete that file; the scripts then ask for `BAO_TOKEN`.

Expect 20–30 minutes for a first run. Most of it is phase 3.

## 5. Check it worked

```bash
export KUBECONFIG=$PWD/.local/kubeconfig
make status                                   # nodes, Argo CD apps, demo secret
kubectl -n demo get secret demo-credentials -o jsonpath='{.data.password}' | base64 -d; echo
eval "$(scripts/openbao.sh env)"; BAO_TOKEN=... bao kv get kv/apps/demo   # same value
make etcdctl ARGS="endpoint status -w table"
make argocd-password                          # Argo CD UI login
```

On a VM: `sudo journalctl -u puppet-apply -e` shows every Puppet run.

## Day 2

- **Change a node's config:** edit `puppet/`, commit, push. Every node pulls and applies within 15 minutes,
  or right away with `sudo systemctl start puppet-apply`.
- **Change something in the cluster:** edit `k8s/`, push. Argo CD syncs it.
- **Add an app secret:** `bao kv put kv/apps/<name> key=value`, then an `ExternalSecret` under `k8s/`.
- **After a power cut:** OpenBao comes back sealed. Run `make unseal`. Nodes keep working on their cached
  secrets until then.
- **Resize a VM:** edit `inventory.yaml`, `make cluster`.
- **Upgrade Kubernetes:** follow the kubeadm upgrade docs on cp1, then each worker. Once a node is done, bump
  `versions.kubernetes` so Puppet pins the new packages instead of fighting you.

## etcd experiments

`sudo ectl …` on any etcd node, or `make etcdctl ARGS="…"` from your workstation.

1. **Quorum:** `make etcdctl ARGS="member list -w table"`, then on etcd3 `sudo systemctl stop etcd`.
   `kubectl get pods -A` still works. Stop etcd2 too: writes fail and `kubectl apply` hangs. Start both again.
2. **Snapshot and restore:** `make etcdctl ARGS="snapshot save /tmp/snap.db"`, delete a namespace, then
   restore with `etcdutl snapshot restore` onto each member's data dir. The etcd docs walk through the
   per-member flags.
3. **Replace a member:** `make etcdctl ARGS="member remove <id>"`, `tofu -chdir=terraform destroy
   -target='proxmox_virtual_environment_vm.node["etcd2"]'`, `make etcdctl ARGS="member add etcd2
   --peer-urls=https://192.168.1.42:2380"`, create `puppet/data/nodes/etcd2.yaml` with
   `etcd_initial_cluster_state: "existing"`, push, then `make cluster`.
4. **Compaction and defrag:** create a few thousand ConfigMaps, watch `endpoint status` DB size, then
   `compaction <rev>` and `defrag`.
5. **Slow disk:** throttle etcd1's disk in Proxmox (Hardware → Hard Disk → Bandwidth), then watch leader
   changes and `etcd_disk_wal_fsync_duration_seconds` on `curl http://127.0.0.1:2381/metrics` from the node.
6. **Rolling upgrade to etcd 3.7:** upgrade one member at a time with a node override, e.g.
   `puppet/data/nodes/etcd1.yaml` containing `versions: { etcd: "v3.7.1" }`. Push, run
   `sudo systemctl start puppet-apply` on etcd1, check health, then repeat for etcd2 and etcd3. Finally move
   the version into `inventory.yaml` and delete the overrides.

## Troubleshooting

| Symptom | Look at |
|---|---|
| VM never finishes creating in OpenTofu | Guest agent not running: VM console, `cloud-init status --long`, `/var/log/cloud-init-output.log` |
| `lookup() did not find a value for 'join_token'` | Node couldn't fetch secrets: `sudo /opt/infra/scripts/node/fetch-secrets.sh`. Is OpenBao unsealed? |
| `kubeadm init` failed halfway | On cp1: `sudo kubeadm reset -f && sudo systemctl start puppet-apply` (Puppet puts the CA back first) |
| Workers not joining | `sudo journalctl -u puppet-apply` on the worker. Is cp1's API up on :6443? |
| ClusterSecretStore not Valid | Ran `make openbao-k8s-auth`? `kubectl describe clustersecretstore openbao` |
| `git clone` fails in cloud-init | Repo must be reachable from the VMs (public, or see below) |

## Private repo

Two places clone the repo: cloud-init on each VM, and Argo CD. For a private repo, use a read-only deploy
key: add it to cloud-init `write_files` plus an SSH `repo.url`, and register it with Argo CD
(`argocd repo add`). Or run Gitea on the lab and mirror the repo there.

## Security trade-offs (fine for a homelab, know them anyway)

- The OpenBao TLS key and the AppRole secret IDs travel in cloud-init. They end up in the OpenTofu state
  (`terraform/terraform.tfstate`) and in `/var/lib/vz/snippets` on the Proxmox host. Keep both private.
- AppRole secret IDs don't expire (VMs re-read secrets every run) but only work from their role's node IPs.
- OpenBao is initialised with a single unseal key. Use 5 shares / threshold 3 if you want to practise Shamir.
- The Proxmox token has Administrator. Narrow it to a custom role once everything works.

## Versions pinned here

Kubernetes 1.37.1 (needs containerd 2.x, installed from Docker's repo), etcd v3.6.14, OpenBao 2.7.1,
Argo CD v3.6.1, OpenVox 8, Ubuntu 24.04. Bump them in `inventory.yaml` and
`k8s/bootstrap/argocd/kustomization.yaml`.
