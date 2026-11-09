#!/usr/bin/env bash
set -euo pipefail

TEMPLATE_ID=${1:-9024}
STORAGE=${STORAGE:-local-lvm}
BRIDGE=${BRIDGE:-vmbr0}
DISK_SIZE=${DISK_SIZE:-40G}
TEMPLATE_NAME=${TEMPLATE_NAME:-ubuntu-2404-k3s}
IMAGE_BASE=https://cloud-images.ubuntu.com/noble/current
IMAGE=noble-server-cloudimg-amd64.img
WORK=/var/lib/vz/template/k3s-build

[[ $EUID -eq 0 ]] || { echo "run as root on the Proxmox host" >&2; exit 1; }
if qm status "$TEMPLATE_ID" >/dev/null 2>&1; then
  echo "VM/template $TEMPLATE_ID already exists" >&2
  exit 1
fi
command -v virt-customize >/dev/null || apt-get install -y libguestfs-tools

mkdir -p "$WORK"
cd "$WORK"
curl -fsSLO "$IMAGE_BASE/SHA256SUMS"
if ! grep " \*$IMAGE\$" SHA256SUMS | sha256sum -c --status 2>/dev/null; then
  curl -fL -o "$IMAGE" "$IMAGE_BASE/$IMAGE"
  grep " \*$IMAGE\$" SHA256SUMS | sha256sum -c
fi

cp "$IMAGE" build.img
qemu-img resize build.img 12G
virt-customize -a build.img \
  --run-command 'growpart /dev/sda 1 && resize2fs /dev/sda1' \
  --run-command 'export DEBIAN_FRONTEND=noninteractive && apt-get update -q && apt-get -q -y upgrade && apt-get -q -y install --no-install-recommends linux-generic-hwe-24.04 qemu-guest-agent open-iscsi nfs-common cryptsetup && apt-get clean' \
  --run-command 'k=$(ls /lib/modules | sort -V | tail -1); for m in iscsi_tcp nfs dm_crypt; do modinfo -k "$k" "$m" >/dev/null || { echo "missing kernel module $m in $k" >&2; exit 1; }; done' \
  --run-command 'systemctl enable iscsid qemu-guest-agent' \
  --run-command 'rm -f /etc/ssh/ssh_host_*' \
  --truncate /etc/machine-id

qm create "$TEMPLATE_ID" \
  --name "$TEMPLATE_NAME" \
  --ostype l26 \
  --machine q35 \
  --cpu host \
  --cores 2 \
  --memory 4096 \
  --balloon 0 \
  --scsihw virtio-scsi-single \
  --net0 "virtio,bridge=$BRIDGE" \
  --serial0 socket \
  --vga serial0 \
  --agent enabled=1,fstrim_cloned_disks=1 \
  --onboot 0

qm set "$TEMPLATE_ID" --scsi0 "$STORAGE:0,import-from=$WORK/build.img,discard=on,ssd=1,iothread=1"
qm set "$TEMPLATE_ID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0
qm disk resize "$TEMPLATE_ID" scsi0 "$DISK_SIZE"
qm template "$TEMPLATE_ID"
rm -f build.img

echo "template $TEMPLATE_ID ($TEMPLATE_NAME) ready"
