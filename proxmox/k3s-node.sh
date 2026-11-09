#!/usr/bin/env bash
# Clone the k3s template into a new agent node with a static IP and join it to the cluster.
# Usage: K3S_TOKEN=... ./k3s-node.sh VMID NAME IP [CORES] [MEMORY_MB] [DISK]
#   e.g. K3S_TOKEN=$(cat token) ./k3s-node.sh 260 wrkr-192-168-1-191 192.168.1.191 4 8192 200G
# Env: TEMPLATE_ID (9024) STORAGE (local-lvm) GATEWAY (192.168.1.254) NAMESERVER (8.8.8.8)
#      K3S_URL (https://192.168.1.186:6443) K3S_VERSION (v1.36.2+k3s1) CI_USER (christian)
#      SSH_PUBKEY_FILE (first non-root@ key in ~/.ssh/authorized_keys) SNIPPETS (local:/var/lib/vz/snippets)
#      CLONE_BWLIMIT KiB/s (102400, keeps etcd on the same disk responsive)
#      ZONE (Proxmox host short name) -> node label topology.kubernetes.io/zone
set -euo pipefail

[[ $# -ge 3 ]] || { sed -n '2,8p' "$0"; exit 2; }
VMID=$1 NODE_NAME=$2 IP=$3 CORES=${4:-4} MEMORY=${5:-8192} DISK=${6:-200G}

: "${K3S_TOKEN:?set K3S_TOKEN (cat /var/lib/rancher/k3s/server/node-token on the control plane)}"
TEMPLATE_ID=${TEMPLATE_ID:-9024}
STORAGE=${STORAGE:-local-lvm}
GATEWAY=${GATEWAY:-192.168.1.254}
NAMESERVER=${NAMESERVER:-8.8.8.8}
K3S_URL=${K3S_URL:-https://192.168.1.186:6443}
K3S_VERSION=${K3S_VERSION:-v1.36.2+k3s1}
CI_USER=${CI_USER:-christian}
ZONE=${ZONE:-$(hostname -s)}
SNIPPETS=${SNIPPETS:-local:/var/lib/vz/snippets}
SNIPPET_STORE=${SNIPPETS%%:*}
SNIPPET_DIR=${SNIPPETS#*:}

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
USERDATA_TEMPLATE=$HERE/cloud-init/k3s-agent.yaml
REGISTRIES=$HERE/../k3s/registries.yaml

[[ $EUID -eq 0 ]] || { echo "run as root on the Proxmox host" >&2; exit 1; }
command -v envsubst >/dev/null || apt-get install -y gettext-base
[[ -f $USERDATA_TEMPLATE && -f $REGISTRIES ]] || { echo "missing $USERDATA_TEMPLATE or $REGISTRIES" >&2; exit 1; }
if qm status "$VMID" >/dev/null 2>&1; then echo "VM $VMID already exists" >&2; exit 1; fi
if ping -c1 -W1 "$IP" >/dev/null 2>&1; then echo "$IP already answers ping" >&2; exit 1; fi

if [[ -n ${SSH_PUBKEY_FILE:-} ]]; then
  SSH_PUBKEY=$(head -1 "$SSH_PUBKEY_FILE")
else
  SSH_PUBKEY=$(grep -E '^(ssh-|ecdsa-)' ~/.ssh/authorized_keys | grep -v -E ' root@[^ ]+$' | head -1)
fi
[[ -n $SSH_PUBKEY ]] || { echo "no SSH public key found; set SSH_PUBKEY_FILE" >&2; exit 1; }

if ! pvesm status --content snippets 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$SNIPPET_STORE"; then
  echo "storage '$SNIPPET_STORE' has no 'snippets' content; enable it, e.g.:" >&2
  echo "  pvesm set $SNIPPET_STORE --content \$(pvesm config $SNIPPET_STORE | awk '/content/{print \$2}'),snippets" >&2
  exit 1
fi
mkdir -p "$SNIPPET_DIR"
SNIPPET=$VMID-k3s-agent.yaml

REGISTRIES_YAML=$(sed 's/^/      /' "$REGISTRIES")
export NODE_NAME CI_USER SSH_PUBKEY K3S_URL K3S_TOKEN K3S_VERSION REGISTRIES_YAML ZONE
umask 077
envsubst '${NODE_NAME} ${CI_USER} ${SSH_PUBKEY} ${K3S_URL} ${K3S_TOKEN} ${K3S_VERSION} ${REGISTRIES_YAML} ${ZONE}' \
  < "$USERDATA_TEMPLATE" > "$SNIPPET_DIR/$SNIPPET"

qm clone "$TEMPLATE_ID" "$VMID" --name "$NODE_NAME" --full 1 --storage "$STORAGE" --bwlimit "${CLONE_BWLIMIT:-102400}"
qm set "$VMID" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --ipconfig0 "ip=$IP/24,gw=$GATEWAY" \
  --nameserver "$NAMESERVER" \
  --cicustom "user=$SNIPPET_STORE:snippets/$SNIPPET" \
  --onboot 1
qm disk resize "$VMID" scsi0 "$DISK"
qm start "$VMID"

echo "started $NODE_NAME ($IP) as VM $VMID"
echo "watch: kubectl get node $NODE_NAME -w"
echo "the snippet contains the join token; once the node is Ready: rm $SNIPPET_DIR/$SNIPPET"
