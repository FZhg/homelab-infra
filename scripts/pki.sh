#!/usr/bin/env bash
# Creates every CA, certificate and token the lab needs, in .local/pki (gitignored).
# Safe to re-run: existing files are kept. Delete a file to regenerate it.
#
#   homelab-ca      signs OpenBao's TLS cert (every VM trusts it via cloud-init)
#   etcd-ca         signs etcd server/peer certs and etcd client certs
#   k8s-ca          the Kubernetes cluster CA (pre-generated so the join hash is known up front)
set -euo pipefail
cd "$(dirname "$0")/.."

INV=inventory.yaml
D=.local/pki
mkdir -p "$D"
chmod 700 .local "$D"

domain=$(yq '.network.domain' "$INV")
bao_ip=$(yq '.nodes.openbao.ip' "$INV")
etcd_names=$(yq '.nodes | to_entries | map(select(.value.role == "etcd")) | .[].key' "$INV")

ext=$(mktemp)
trap 'rm -f "$ext" "$D"/*.csr' EXIT

# ca <name> <common name> <key bits>
ca() {
  local name=$1 cn=$2 bits=$3
  [ -f "$D/$name.crt" ] && { echo "keep  $name.crt"; return; }
  openssl genrsa -out "$D/$name.key" "$bits" 2>/dev/null
  openssl req -new -key "$D/$name.key" -subj "/CN=$cn" -out "$D/$name.csr"
  printf '%s\n' \
    "basicConstraints=critical,CA:TRUE" \
    "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign,cRLSign" \
    "subjectKeyIdentifier=hash" > "$ext"
  openssl x509 -req -sha256 -days 3650 -in "$D/$name.csr" -signkey "$D/$name.key" \
    -extfile "$ext" -out "$D/$name.crt" 2>/dev/null
  echo "new   $name.crt"
}

# leaf <name> <ca> <common name> <extendedKeyUsage> [subjectAltName]
leaf() {
  local name=$1 ca=$2 cn=$3 eku=$4 san=${5:-}
  [ -f "$D/$name.crt" ] && { echo "keep  $name.crt"; return; }
  openssl genrsa -out "$D/$name.key" 2048 2>/dev/null
  openssl req -new -key "$D/$name.key" -subj "/CN=$cn" -out "$D/$name.csr"
  printf '%s\n' \
    "basicConstraints=CA:FALSE" \
    "keyUsage=critical,digitalSignature,keyEncipherment" \
    "extendedKeyUsage=$eku" > "$ext"
  [ -n "$san" ] && echo "subjectAltName=$san" >> "$ext"
  openssl x509 -req -sha256 -days 825 -in "$D/$name.csr" \
    -CA "$D/$ca.crt" -CAkey "$D/$ca.key" -CAcreateserial \
    -extfile "$ext" -out "$D/$name.crt" 2>/dev/null
  echo "new   $name.crt"
}

ca homelab-ca "Homelab CA" 4096
ca etcd-ca    "etcd-ca"    2048
ca k8s-ca     "kubernetes" 2048

# OpenBao server certificate
leaf openbao homelab-ca openbao serverAuth "DNS:openbao,DNS:openbao.$domain,IP:$bao_ip"

# One etcd cert for all members, used as both server and peer cert.
etcd_san="DNS:localhost,IP:127.0.0.1"
for n in $etcd_names; do
  ip=$(yq ".nodes.$n.ip" "$INV")
  etcd_san="$etcd_san,DNS:$n,DNS:$n.$domain,IP:$ip"
done
leaf etcd-server etcd-ca etcd serverAuth,clientAuth "$etcd_san"

# Client certs: the API server's, and one for you to run etcdctl from your workstation.
leaf etcd-apiserver-client etcd-ca kube-apiserver-etcd-client clientAuth
leaf etcd-admin            etcd-ca etcd-admin                 clientAuth

# kubeadm bootstrap token ([a-z0-9]{6}.[a-z0-9]{16}) and the CA hash workers pin.
if [ ! -f "$D/join-token" ]; then
  echo "$(openssl rand -hex 3).$(openssl rand -hex 8)" > "$D/join-token"
  echo "new   join-token"
fi
openssl x509 -pubkey -noout -in "$D/k8s-ca.crt" |
  openssl rsa -pubin -outform der 2>/dev/null |
  openssl dgst -sha256 -hex | sed 's/^.* //' > "$D/join-ca-hash"

chmod 600 "$D"/*.key "$D/join-token"
echo "PKI ready in $D"
