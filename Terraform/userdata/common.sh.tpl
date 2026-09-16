#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/userdata.log) 2>&1

# ---------------------------------------------------------------------------
# 0. Hostname - set to the Terraform resource's Name (control-plane, worker-1, ...)
# so `hostname`/`kubectl get nodes` show something meaningful instead of the
# default ip-10-0-x-x.ec2.internal. Also updates /etc/hosts so the node
# resolves its own new name locally (avoids "sudo: unable to resolve host" noise).
# ---------------------------------------------------------------------------
hostnamectl set-hostname "${node_name}"
sed -i "s/^127.0.1.1.*/127.0.1.1 ${node_name}/" /etc/hosts || \
  echo "127.0.1.1 ${node_name}" >> /etc/hosts

# ---------------------------------------------------------------------------
# 1. Disable swap - kubelet refuses to start with swap on
# ---------------------------------------------------------------------------
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# ---------------------------------------------------------------------------
# 2. Kernel modules + sysctl required for pod networking
# ---------------------------------------------------------------------------
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# ---------------------------------------------------------------------------
# 3. containerd
# ---------------------------------------------------------------------------
apt-get update
apt-get install -y ca-certificates curl gnupg apt-transport-https

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get install -y containerd.io

mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
# The classic kubeadm gotcha: kubelet and containerd MUST agree on cgroup driver
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# ---------------------------------------------------------------------------
# 4. kubeadm / kubelet / kubectl / cri-tools from the official pkgs.k8s.io repo
#
# cri-tools (crictl) is NOT a declared dependency of kubeadm on this repo -
# `apt-cache depends kubeadm` confirms it pulls in nothing. It has to be
# installed explicitly or you end up with no crictl on any node at all.
# Pinned and held alongside the other three so it can't drift independently
# and end up mismatched with the installed containerd version.
# ---------------------------------------------------------------------------
K8S_VERSION="${kubernetes_version}"

curl -fsSL "https://pkgs.k8s.io/core:/stable:/v$${K8S_VERSION}/deb/Release.key" | \
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$${K8S_VERSION}/deb/ /" | \
  tee /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y kubelet kubeadm kubectl cri-tools
apt-mark hold kubelet kubeadm kubectl cri-tools
systemctl enable kubelet

# crictl config - without this it doesn't know which socket to use and
# falls back to probing deprecated default endpoints
cat <<EOF | tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

# ---------------------------------------------------------------------------
# 5. Shell UX - bash completion + `k` alias for kubectl, for the ubuntu user
#
# userdata runs as root, so ~/.bashrc would resolve to /root/.bashrc and
# silently configure a shell you never actually use - path is made explicit
# here and ownership is fixed afterward so the ubuntu user (who you SSH in
# as) gets it on next login.
# ---------------------------------------------------------------------------
apt-get install -y bash-completion

UBUNTU_BASHRC=/home/ubuntu/.bashrc
{
  echo 'source /usr/share/bash-completion/bash_completion'
  echo 'source <(kubectl completion bash)'
  echo 'alias k=kubectl'
  echo 'complete -F __start_kubectl k'
} >> "$UBUNTU_BASHRC"

chown ubuntu:ubuntu "$UBUNTU_BASHRC"

# ---------------------------------------------------------------------------
# Give kubelet the node's private IP explicitly - avoids it picking the
# wrong interface on multi-NIC instances
# IMDSv2 token - required if IMDSv2 is enforced on this instance (default
# on newer accounts/launch templates). Every IMDS curl below uses this.
# ---------------------------------------------------------------------------
IMDS_TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

LOCAL_IP=$(curl -s -H "X-aws-ec2-metadata-token: $${IMDS_TOKEN}" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

cat <<EOF | tee /etc/default/kubelet
KUBELET_EXTRA_ARGS=--node-ip=$${LOCAL_IP}
EOF