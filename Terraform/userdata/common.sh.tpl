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
# 4. kubeadm / kubelet / kubectl from the official pkgs.k8s.io repo
# ---------------------------------------------------------------------------
K8S_VERSION="${kubernetes_version}"

curl -fsSL "https://pkgs.k8s.io/core:/stable:/v$${K8S_VERSION}/deb/Release.key" | \
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$${K8S_VERSION}/deb/ /" | \
  tee /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable kubelet

# Give kubelet the node's private IP explicitly - avoids it picking the
# wrong interface on multi-NIC instances
LOCAL_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
cat <<EOF | tee /etc/default/kubelet
KUBELET_EXTRA_ARGS=--node-ip=$${LOCAL_IP}
EOF