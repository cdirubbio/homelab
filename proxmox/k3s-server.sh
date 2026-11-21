#!/usr/bin/env bash
# Clone the k3s template into a control-plane (server) node with a static IP.
# Usage: MODE=restore|init|join [env...] ./k3s-server.sh VMID NAME IP [CORES] [MEMORY_MB] [DISK]
#
#   restore  Rebuild the existing CP from an etcd snapshot, keeping its IP (Cilium, agents and
#            kubeconfigs point at it). Shut the old CP down first.
#              SNAPSHOT=/root/cp-migration/<snap>        etcd snapshot file on this host
#              K3S_TOKEN=<full K10...::server:... token>  /var/lib/rancher/k3s/server/token of the old CP
#              NODE_PASSWORD_FILE=<file>  (optional) /etc/rancher/node/password of the old CP; without it
#                                         the stale <name>.node-password.k3s secret is deleted instead
#      e.g. MODE=restore SNAPSHOT=/root/cp-migration/snap K3S_TOKEN=$(cat /root/cp-migration/token) \
#             NODE_PASSWORD_FILE=/root/cp-migration/node-password ./k3s-server.sh 186 cp-192-168-1-186 192.168.1.186
#   init     Start a brand-new cluster (K3S_TOKEN optional; k3s generates one if unset).
#   join     Add another server to the running cluster (HA). K3S_TOKEN and K3S_URL required.
#            Note: 2 etcd members have no fault tolerance; go to 3 or stay at 1.
#
# Env: TEMPLATE_ID (9024) STORAGE (local-lvm) GATEWAY (192.168.1.254) NAMESERVER (8.8.8.8)
#      K3S_URL (https://192.168.1.186:6443, join only) K3S_VERSION (v1.37.2+k3s1) CI_USER (christian)
#      SSH_PUBKEY_FILE (first non-root@ key in ~/.ssh/authorized_keys) SNIPPETS (local:/var/lib/vz/snippets)
#      CLONE_BWLIMIT KiB/s (102400) ZONE (Proxmox host short name)
# Server flags live in k3s/server-config.yaml; keep them identical to the running cluster.
set -euo pipefail

[[ $# -ge 3 ]] || { sed -n '2,24p' "$0"; exit 2; }
VMID=$1 NODE_NAME=$2 IP=$3 CORES=${4:-4} MEMORY=${5:-8192} DISK=${6:-150G}

MODE=${MODE:?set MODE=restore, init or join}
TEMPLATE_ID=${TEMPLATE_ID:-9024}
STORAGE=${STORAGE:-local-lvm}
GATEWAY=${GATEWAY:-192.168.1.254}
NAMESERVER=${NAMESERVER:-8.8.8.8}
K3S_URL=${K3S_URL:-https://192.168.1.186:6443}
K3S_VERSION=${K3S_VERSION:-v1.37.2+k3s1}
K3S_TOKEN=${K3S_TOKEN:-}
CI_USER=${CI_USER:-christian}
ZONE=${ZONE:-$(hostname -s)}
SNIPPETS=${SNIPPETS:-local:/var/lib/vz/snippets}
SNIPPET_STORE=${SNIPPETS%%:*}
SNIPPET_DIR=${SNIPPETS#*:}

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
USERDATA_TEMPLATE=$HERE/cloud-init/k3s-server.yaml
SERVER_CONFIG=$HERE/k3s/server-config.yaml
REGISTRIES=$HERE/k3s/registries.yaml

die() { echo "error: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root on the Proxmox host"
for f in "$USERDATA_TEMPLATE" "$SERVER_CONFIG" "$REGISTRIES"; do [[ -f $f ]] || die "missing $f"; done

case $MODE in
  restore)
    [[ -n ${SNAPSHOT:-} && -f $SNAPSHOT ]] || die "restore needs SNAPSHOT=<etcd snapshot file on this host>"
    [[ $K3S_TOKEN == K10*::server:* ]] || die "restore needs the full server token (K10...::server:...) of the old cluster"
    [[ -z ${NODE_PASSWORD_FILE:-} || -f $NODE_PASSWORD_FILE ]] || die "NODE_PASSWORD_FILE $NODE_PASSWORD_FILE not found"
    START_K3S=false
    CLUSTER_YAML=$(printf 'cluster-init: true\ntoken: "%s"\n' "$K3S_TOKEN") ;;
  init)
    START_K3S=true
    CLUSTER_YAML='cluster-init: true'
    [[ -n $K3S_TOKEN ]] && CLUSTER_YAML+=$(printf '\ntoken: "%s"' "$K3S_TOKEN") ;;
  join)
    [[ -n $K3S_TOKEN ]] || die "join needs K3S_TOKEN"
    START_K3S=true
    CLUSTER_YAML=$(printf 'server: %s\ntoken: "%s"\n' "$K3S_URL" "$K3S_TOKEN") ;;
  *) die "MODE must be restore, init or join" ;;
esac

command -v envsubst >/dev/null || apt-get install -y gettext-base
if qm status "$VMID" >/dev/null 2>&1; then die "VM $VMID already exists"; fi
if ping -c1 -W1 "$IP" >/dev/null 2>&1; then die "$IP already answers ping (shut the old CP down first)"; fi

if [[ -n ${SSH_PUBKEY_FILE:-} ]]; then
  SSH_PUBKEY=$(head -1 "$SSH_PUBKEY_FILE")
else
  SSH_PUBKEY=$(grep -E '^(ssh-|ecdsa-)' ~/.ssh/authorized_keys | grep -v -E ' root@[^ ]+$' | head -1)
fi
[[ -n $SSH_PUBKEY ]] || die "no SSH public key found; set SSH_PUBKEY_FILE"
# this host's own key, so the restore steps below can reach the VM
[[ -f ~/.ssh/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519
AUTOMATION_PUBKEY=$(cat ~/.ssh/id_ed25519.pub)

if ! pvesm status --content snippets 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$SNIPPET_STORE"; then
  die "storage '$SNIPPET_STORE' has no 'snippets' content; enable it with pvesm set $SNIPPET_STORE --content <existing>,snippets"
fi
mkdir -p "$SNIPPET_DIR"
SNIPPET=$VMID-k3s-server.yaml

indent() { sed 's/^/      /' "$@"; }
SERVER_CONFIG_YAML=$(grep -v '^#' "$SERVER_CONFIG" | indent)
CLUSTER_YAML=$(printf '%s\n' "$CLUSTER_YAML" | indent)
REGISTRIES_YAML=$(indent "$REGISTRIES")
export NODE_NAME CI_USER SSH_PUBKEY AUTOMATION_PUBKEY ZONE K3S_VERSION START_K3S \
       SERVER_CONFIG_YAML CLUSTER_YAML REGISTRIES_YAML
umask 077
envsubst '${NODE_NAME} ${CI_USER} ${SSH_PUBKEY} ${AUTOMATION_PUBKEY} ${ZONE} ${K3S_VERSION} ${START_K3S} ${SERVER_CONFIG_YAML} ${CLUSTER_YAML} ${REGISTRIES_YAML}' \
  < "$USERDATA_TEMPLATE" > "$SNIPPET_DIR/$SNIPPET"

qm clone "$TEMPLATE_ID" "$VMID" --name "$NODE_NAME" --full 1 --storage "$STORAGE" --bwlimit "${CLONE_BWLIMIT:-102400}"
qm set "$VMID" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --balloon "$MEMORY" \
  --ipconfig0 "ip=$IP/24,gw=$GATEWAY" \
  --nameserver "$NAMESERVER" \
  --cicustom "user=$SNIPPET_STORE:snippets/$SNIPPET" \
  --tags "k8s-cluster;k8s-master" \
  --onboot 1
qm disk resize "$VMID" scsi0 "$DISK"
qm start "$VMID"
echo "started $NODE_NAME ($IP) as VM $VMID in $MODE mode"

if [[ $MODE != restore ]]; then
  echo "watch: kubectl get node $NODE_NAME -w"
  echo "the snippet contains the token; once the node is Ready: rm $SNIPPET_DIR/$SNIPPET"
  exit 0
fi

# ---- restore: wait for first boot, copy the snapshot in, reset etcd from it, start k3s ----
SSH=(ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "$CI_USER@$IP")
vm() { "${SSH[@]}" "$@"; }

echo "waiting for SSH and cloud-init (package upgrade + k3s install)..."
for _ in $(seq 1 120); do vm true 2>/dev/null && break; sleep 5; done
vm true || die "no SSH to $IP after 10 minutes; check: qm terminal $VMID"
vm 'cloud-init status --wait >/dev/null; cloud-init status' | grep -q 'status: done' \
  || die "cloud-init did not finish cleanly; check /var/log/cloud-init-output.log on $IP"
vm 'test -x /usr/local/bin/k3s' || die "k3s was not installed by cloud-init"

SNAP_NAME=$(basename "$SNAPSHOT")
SNAP_DIR=/var/lib/rancher/k3s/server/db/snapshots
vm "sudo install -d -m 700 $SNAP_DIR /etc/rancher/node"
vm "sudo sh -c 'umask 077; cat > $SNAP_DIR/$SNAP_NAME'" < "$SNAPSHOT"
[[ $(vm "sudo sha256sum $SNAP_DIR/$SNAP_NAME" | cut -d' ' -f1) == $(sha256sum "$SNAPSHOT" | cut -d' ' -f1) ]] \
  || die "snapshot checksum mismatch after copy"
if [[ -n ${NODE_PASSWORD_FILE:-} ]]; then
  vm "sudo sh -c 'umask 077; cat > /etc/rancher/node/password'" < "$NODE_PASSWORD_FILE"
fi

echo "restoring etcd from $SNAP_NAME..."
vm "sudo k3s server --cluster-reset --cluster-reset-restore-path=$SNAP_DIR/$SNAP_NAME > /tmp/cluster-reset.log 2>&1 || true"
vm 'grep -q "restart without --cluster-reset" /tmp/cluster-reset.log' \
  || { vm 'tail -20 /tmp/cluster-reset.log' >&2; die "cluster-reset did not complete; full log in /tmp/cluster-reset.log on $IP"; }

vm 'sudo systemctl start k3s'
echo "waiting for the API server..."
for _ in $(seq 1 60); do vm 'sudo k3s kubectl get --raw=/readyz' >/dev/null 2>&1 && break; sleep 5; done
vm 'sudo k3s kubectl get --raw=/readyz' >/dev/null 2>&1 \
  || { vm 'sudo journalctl -u k3s --no-pager | grep -E "level=(fatal|error)" | grep -v "503 response" | tail -5' >&2
       die "API server not ready after 5 minutes"; }

if [[ -z ${NODE_PASSWORD_FILE:-} ]]; then
  # the restored etcd holds the old VM's node password; drop it so this node can register
  vm "sudo k3s kubectl -n kube-system delete secret $NODE_NAME.node-password.k3s --ignore-not-found"
fi

for _ in $(seq 1 60); do
  [[ $(vm "sudo k3s kubectl get node $NODE_NAME -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null) == True ]] && break
  sleep 5
done
vm 'sudo k3s kubectl get nodes -o wide'

cat <<EOF

Restore done. Remaining steps:
  1. kubectl uncordon $NODE_NAME            (if it was drained before the snapshot)
  2. Longhorn: the node record still points at the old disk (DiskFilesystemChanged). With no replicas
     on this node, swap the disk entry:
       kubectl -n longhorn-system get nodes.longhorn.io $NODE_NAME -o jsonpath='{.spec.disks}'
       kubectl -n longhorn-system patch nodes.longhorn.io $NODE_NAME --type merge -p \\
         '{"spec":{"disks":{"<old-disk-name>":null,"default-disk-$VMID":{"allowScheduling":true,"evictionRequested":false,"diskType":"filesystem","path":"/var/lib/longhorn/","storageReserved":0,"tags":[]}}}}'
  3. Restart controllers left in CrashLoopBackOff from the API outage (cilium-operator, cert-manager, flux).
  4. rm $SNIPPET_DIR/$SNIPPET   (contains the token); keep the old CP VM stopped until you're confident.
EOF
