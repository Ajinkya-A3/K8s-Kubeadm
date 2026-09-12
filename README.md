# Kubeadm on EC2 — self-managed Kubernetes lab

A hand-built Kubernetes cluster on AWS EC2 using `kubeadm`, provisioned with
Terraform. Built as a learning project to understand the control-plane,
CRI, and CNI internals that managed services like EKS abstract away —
everything from certificate bootstrapping to CNI IP allocation is done and
understood step by step here, not hidden behind a managed control plane.

**Kubernetes version:** 1.35

## Repo structure

```
├── LICENSE
├── README.md
└── Terraform
    ├── vpc.tf              # VPC, subnets, IGW, route tables
    ├── security-group.tf   # control-plane-sg and data-plane-sg
    ├── ec2.tf               # control-plane + worker EC2 instances
    ├── userdata
    │   └── common.sh.tpl   # node bootstrap script (shared by all nodes)
    ├── variables.tf
    ├── versions.tf
    ├── providers.tf
    └── output.tf
```

## Architecture

```
                         Internet
                             │
                     ┌───────┴────────┐
                     │Internet Gateway│
                     └───────┬────────┘
                             │
                    ┌────────┴──────────┐
                    │  Public Subnet(s) │  (one per AZ)
                    └───┬───────────┬───┘
                        │           │
              control-plane-sg   data-plane-sg
                        │           │
              ┌─────────┴───┐   ┌───┴──────┬──────────┐
              │control-plane│   │ worker-1 │ worker-2 │ ...
              │  (t3.medium)│   │          │          │
              └─────────────┘   └──────────┴──────────┘
```

Single control-plane node (no HA — one etcd member, deliberate for a
learning cluster), N worker nodes, all in public subnets with public IPs
for direct SSH access.

## Terraform — what each file does

- **`vpc.tf`** — VPC (`10.0.0.0/16`), Internet Gateway, one public subnet
  per AZ, shared public route table with a `0.0.0.0/0` route via the IGW.
  Public-only, no NAT — simplest option for a lab, at the cost of every
  node being directly internet-facing (the security groups are the real
  perimeter here).
- **`security-group.tf`** — `control-plane-sg` and `data-plane-sg`, every
  rule as its own `aws_security_group_rule` (not inline `ingress {}`) so
  the two SGs can reference each other as traffic sources without a
  circular-dependency error. Rules cover SSH, the Kubernetes API (6443),
  kubelet (10250), and Calico's VXLAN (4789/udp) and Typha (5473/tcp)
  ports in both directions, plus NodePort (30000–32767) open publicly for
  testing.
- **`ec2.tf`** — one control-plane instance + `var.worker_count` workers.
  AMI resolved via the SSM Parameter Store path for Canonical's current
  Ubuntu 24.04 AMI. Each instance: 20GB `gp3` root volume, public IP,
  `user_data` pointed at `common.sh.tpl` with a per-instance `node_name`.
- **`variables.tf` / `versions.tf` / `providers.tf`** — standard
  scaffolding: variable declarations, Terraform/provider version pins,
  AWS provider/region config.
- **`output.tf`** — control-plane and worker public IPs.

## `userdata/common.sh.tpl`, explained line by line

One shared script for every node — control plane and workers alike get
identical prep, since `kubeadm init`/`kubeadm join` are run **manually**
afterward, not automated in userdata.

```bash
#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/userdata.log) 2>&1
```
`set -euxo pipefail`: exit on any error (`-e`), error on unset variables
(`-u`), print every command before running it (`-x`), and fail the whole
pipeline if any command in a pipe fails, not just the last one
(`pipefail`) — makes failures loud and visible instead of silently
continuing. `exec > >(tee ...)` mirrors all script output to
`/var/log/userdata.log`, so if something goes wrong you can SSH in and
read exactly what happened during boot instead of guessing.

```bash
# 0. Hostname
hostnamectl set-hostname "${node_name}"
sed -i "s/^127.0.1.1.*/127.0.1.1 ${node_name}/" /etc/hosts || \
  echo "127.0.1.1 ${node_name}" >> /etc/hosts
```
Sets the node's hostname to whatever Terraform passed in
(`<cluster>-control-plane`, `<cluster>-worker-1`, ...), matching the EC2
`Name` tag. The `/etc/hosts` line makes the node resolve its own new name
locally — without it, some tools (including `sudo`) print harmless but
annoying "unable to resolve host" warnings.

```bash
# 1. Disable swap
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab
```
kubelet refuses to start with swap active — memory accounting for pod
requests/limits assumes no swap. `swapoff -a` disables it immediately;
commenting the `fstab` entry keeps it off across reboots.

```bash
# 2. Kernel modules + sysctl
modprobe overlay
modprobe br_netfilter
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
```
`overlay` is the kernel module behind OverlayFS, which containerd uses by
default to layer container image filesystems. `br_netfilter` makes
traffic crossing a Linux bridge visible to iptables — without it, pod
traffic that crosses a bridge bypasses kube-proxy's iptables rules
entirely (a classic "why can't my pod reach the Service IP" bug). The two
`bridge-nf-call-*` sysctls are the actual switch that turns that
visibility on; `ip_forward=1` makes the node act as a router, which every
K8s node needs to be, to forward packets between pod and host interfaces.

```bash
# 3. containerd
apt-get install -y containerd.io
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
```
Installs containerd from Docker's apt repo (runc comes along as a
dependency automatically — no separate install needed). `containerd
config default` generates a config file, since containerd ships without
one. The `SystemdCgroup` flip is the single most common first-time
kubeadm failure: Ubuntu/systemd and kubeadm both default to the
**systemd** cgroup driver, but containerd's own compiled default is
**cgroupfs** — if kubelet and containerd disagree, kubelet crash-loops
right after `init`/`join` with cgroup errors in `journalctl -u kubelet`.

```bash
# 4. kubeadm / kubelet / kubectl
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v$${K8S_VERSION}/deb/Release.key" | ...
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable kubelet
```
Installs from the official, per-minor-version `pkgs.k8s.io` repo (the old
`apt.kubernetes.io` repo is dead). `apt-mark hold` pins the three
packages so a routine `apt-get upgrade` can't silently bump the
Kubernetes minor version — unplanned version skew between kubeadm/kubelet
and the control plane is a real way to break a cluster. `systemctl enable
kubelet` makes it start automatically on every boot, even before
`kubeadm init`/`join` has run — kubelet is designed to sit and retry
until it finds a valid config, rather than needing to be started
manually after joining.

```bash
# Node IP pin
IMDS_TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
LOCAL_IP=$(curl -s -H "X-aws-ec2-metadata-token: $${IMDS_TOKEN}" \
  http://169.254.169.254/latest/meta-data/local-ipv4)
cat <<EOF | tee /etc/default/kubelet
KUBELET_EXTRA_ARGS=--node-ip=$${LOCAL_IP}
EOF
```
`169.254.169.254` is the link-local address for the EC2 Instance Metadata
Service (IMDS) — reserved, non-routable, reachable only from inside the
instance itself. This account enforces **IMDSv2**, which requires
fetching a session token first (`PUT /latest/api/token`) and passing it
as a header on every subsequent metadata call — the older unauthenticated
IMDSv1 `GET` silently returns nothing rather than erroring, which cost
real debugging time during this build. The fetched private IP is written
into `/etc/default/kubelet`, read by the kubelet systemd unit at startup
and appended to its command line — this pins the exact IP kubelet
advertises, rather than relying on its own (occasionally wrong, on
multi-interface instances) auto-detection.

## Kubernetes cluster bring-up (manual, over SSH)

Terraform gets every node to "kubeadm/kubelet/kubectl installed,
containerd configured, ready to be initialized." Everything past that is
run by hand.

**1. Initialize the control plane** — SSH in, confirm the node's real
private IP (`echo $LOCAL_IP` or re-fetch via the IMDSv2 flow above), then:

```bash
# Replace with your control plane node's private IP
sudo kubeadm init \
  --control-plane-endpoint=<CP_PRIVATE_IP>:6443 \
  --apiserver-advertise-address=<CP_PRIVATE_IP> \
  --pod-network-cidr=<cidr>
```

`--pod-network-cidr` must exactly match whatever CIDR gets used in the
CNI's install manifest later — this is the most common way to break a
fresh cluster if the two disagree.

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

**2. Install Calico** (see below) so pods can actually get IPs — nodes
stay `NotReady` and `coredns` stays `Pending` until a CNI is applied.

**3. Join the workers** — from the control plane, print a fresh join
command:

```bash
kubeadm token create --print-join-command
```

Copy the output and run it with `sudo` on each worker:

```bash
sudo kubeadm join <CP_PRIVATE_IP>:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

Confirm from the control plane:

```bash
kubectl get nodes
```

**Note on `kubectl` access:** it only works where a kubeconfig exists —
`/etc/kubernetes/admin.conf` on the control plane (copied to
`~/.kube/config` above), or a copy of that file pulled onto your laptop
or another machine. Workers never receive an admin kubeconfig from
`kubeadm join`, by design — a worker's job is running kubelet and
workloads as a client of the cluster, not administering it.

## CNI: Calico

Installed via the Tigera Operator (current recommended method):

```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.2/manifests/v1_crd_projectcalico_org.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.2/manifests/tigera-operator.yaml
kubectl rollout status deploy/tigera-operator -n tigera-operator

cat <<'EOF' | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - name: default-ipv4-ippool
      blockSize: 26
      cidr: 10.244.0.0/16              # must match kubeadm's --pod-network-cidr
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
```

**`encapsulation: VXLANCrossSubnet`** — encapsulates pod traffic in VXLAN
only when crossing subnets; same-subnet pod traffic routes directly
without the encapsulation overhead. Chosen over `Always` (simplest, but
always pays the overhead) and `Never` (no encapsulation — requires the
underlying network to already route the pod CIDR, not viable on a plain
VPC without BGP peering).

**The `APIServer` resource** deploys Calico's aggregated API server,
serving Calico's custom resources (`NetworkPolicy`, `GlobalNetworkPolicy`,
`Tier`, etc.) as first-class Kubernetes API resources. Needed for
Calico-specific features like tiered policy; optional if only using plain
Kubernetes `NetworkPolicy` objects.

## Testing

A basic nginx Deployment (5 replicas) + NodePort Service validates the
full path: scheduler → CNI pod IP assignment → kube-proxy Service routing
→ container. `kubectl get pods -o wide` to check pod placement/IPs,
`curl http://<worker-public-ip>:30080` to confirm external reachability.

## Lessons learned (kept here on purpose)

- **IMDSv2 is enforced on this account** — unauthenticated IMDS calls
  return empty rather than erroring, a quiet failure mode worth knowing
  about ahead of time.
- **A wrong `kubeadm init`** (wrong advertise-address, wrong pod CIDR)
  can't be patched live. It requires `kubeadm reset -f` on every node
  (control plane and all workers), clearing `/etc/cni/net.d` and
  flushing iptables (`kubeadm reset` doesn't remove kube-proxy/CNI's
  iptables rules on its own), then a clean re-init and a freshly
  generated join command — stale tokens from a bad init stay stale even
  after the worker itself is reset.
- **CIDR consistency matters more than the specific range chosen** — what
  breaks things is `kubeadm init --pod-network-cidr` and the CNI's
  install manifest disagreeing with each other, not the specific value.

## Next steps

- Swap Calico for Cilium and compare (eBPF-native dataplane, Hubble
  observability).
- Document a minor-version upgrade (etcd snapshot first, control plane
  before workers, one worker at a time).
- Automate `kubeadm init`/`join` via SSM Parameter Store instead of
  manual SSH, once the manual process is fully understood.

## Cost note

All instances run 24/7 unless stopped — `terraform destroy` when not
actively using the cluster, or stop instances manually (compute billing
stops; EBS storage still bills while stopped).
