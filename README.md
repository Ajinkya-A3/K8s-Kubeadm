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
├── Version-Upgrade.md   # manual kubeadm minor-version upgrade walkthrough
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
Installs containerd from Docker's apt repo. **Correction from an earlier
version of this doc:** runc is *not* pulled in as a separate apt
dependency — `apt-cache depends containerd.io` only lists `libc6` and
`libseccomp2`. Instead, `containerd.io` bundles its own runc binary and
declares `Conflicts`/`Replaces` against the standalone `runc` package, so
apt removes any separate `runc` install and uses the bundled one. Net
effect is the same (you get a working runc for free), but the mechanism
is bundling, not a dependency — worth knowing if you're ever debugging
which runc binary is actually in use (`dpkg -S $(which runc)` will
attribute it to `containerd.io`, not a `runc` package).

`containerd config default` generates a config file, since containerd
ships without one. The `SystemdCgroup` flip is the single most common
first-time kubeadm failure: Ubuntu/systemd and kubeadm both default to
the **systemd** cgroup driver, but containerd's own compiled default is
**cgroupfs** — if kubelet and containerd disagree, kubelet crash-loops
right after `init`/`join` with cgroup errors in `journalctl -u kubelet`.

```bash
# 4. kubeadm / kubelet / kubectl / cri-tools
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v$${K8S_VERSION}/deb/Release.key" | ...
apt-get install -y kubelet kubeadm kubectl cri-tools
apt-mark hold kubelet kubeadm kubectl cri-tools
systemctl enable kubelet
```
Installs from the official, per-minor-version `pkgs.k8s.io` repo (the old
`apt.kubernetes.io` repo is dead). `apt-mark hold` pins the packages so a
routine `apt-get upgrade` can't silently bump the Kubernetes minor
version — unplanned version skew between kubeadm/kubelet and the control
plane is a real way to break a cluster. `systemctl enable kubelet` makes
it start automatically on every boot, even before `kubeadm init`/`join`
has run — kubelet is designed to sit and retry until it finds a valid
config, rather than needing to be started manually after joining.

**`cri-tools` is included explicitly and is not optional.** Unlike older
Kubernetes packaging, kubeadm on `pkgs.k8s.io` does **not** declare
`cri-tools` as a dependency — `apt-cache depends kubeadm` confirms it
pulls in nothing else. Without this explicit install, `crictl` simply
doesn't exist on the node, silently, with no error at any point in the
bootstrap. It's held alongside the other three packages for the same
reason they're held: an unpinned `cri-tools` bump has broken clusters
before by pulling in a version incompatible with the installed containerd
(a documented failure mode upstream), and it should always move in
lockstep with a planned upgrade, not on its own.

Right after install, a minimal `/etc/crictl.yaml` is written pointing at
the containerd socket — without it, crictl doesn't know which runtime
endpoint to use and falls back to probing deprecated defaults, which
looks like a broken install even once the binary is present:

```bash
cat <<EOF | tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF
```

```bash
# 5. Shell UX
apt-get install -y bash-completion
UBUNTU_BASHRC=/home/ubuntu/.bashrc
{
  echo 'source /usr/share/bash-completion/bash_completion'
  echo 'source <(kubectl completion bash)'
  echo 'alias k=kubectl'
  echo 'complete -F __start_kubectl k'
} >> "$UBUNTU_BASHRC"
chown ubuntu:ubuntu "$UBUNTU_BASHRC"
```
Sets up `kubectl` tab completion and a `k` alias for the `ubuntu` user —
purely quality-of-life, not required for the cluster to function. The
path is written explicitly as `/home/ubuntu/.bashrc` rather than
`~/.bashrc` because userdata runs as **root**; `~` there resolves to
`/root`, which isn't the shell you actually SSH into. Writing to root's
bashrc instead would silently configure a shell nobody uses, so the path
is hardcoded and ownership is corrected afterward with `chown` so the
file is still writable/editable by `ubuntu` going forward.

**Gotcha: this doesn't take effect in your current SSH session.**
`.bashrc` is only read when a new interactive shell starts — appending to
it during userdata just stages the lines for later, it doesn't run them.
If you're SSH'd in from before the instance finished booting (or your
SSH client is reusing a multiplexed connection instead of opening a truly
new one), `k` will show up as `-bash: k: not found` even though the
alias is correctly sitting in the file. Fix is either:
```bash
source ~/.bashrc     # re-read it in the current shell, or
```
```bash
exit                  # or just open a brand-new session
ssh ubuntu@<node-ip>
```
Confirm with `type k` and `complete -p k` — both should resolve once the
file has actually been sourced.

Also worth knowing: Ubuntu 24.04's default `.bashrc` already has a
conditional block that sources `bash-completion` on its own —
```bash
if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
```
— so the explicit `source /usr/share/bash-completion/bash_completion`
line this script appends is redundant (sourced twice, harmless). Not the
cause of the issue above, but a candidate to trim if you clean this
script up later.

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

Terraform gets every node to "kubeadm/kubelet/kubectl/cri-tools installed,
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

An nginx Deployment + NodePort Service validates the full path: scheduler
→ CNI pod IP assignment → kube-proxy Service routing → container.
`kubectl get pods -o wide` to check pod placement/IPs, `curl
http://<worker-public-ip>:30080` to confirm external reachability. Also
used as the workload for zero-downtime testing during manual version
upgrades (topology spread constraints + readiness probe + a
PodDisruptionBudget so draining a node doesn't take the Service down —
see [`Version-Upgrade.md`](./Version-Upgrade.md) for the full manifest).

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
- **`cri-tools` is not a kubeadm dependency on `pkgs.k8s.io`** — it has to
  be installed explicitly or `crictl` is simply absent on every node,
  with no error anywhere in the bootstrap to flag it. Confirmed via
  `apt-cache depends kubeadm` returning nothing. Now installed and held
  alongside kubeadm/kubelet/kubectl in the userdata script.
- **containerd's runc is bundled, not a separate dependency** —
  `containerd.io` ships its own runc and uses `Conflicts`/`Replaces`
  against the standalone `runc` package rather than depending on it.
  Functionally the same outcome, but worth knowing when tracing which
  package actually owns the runc binary on a node.

## Next steps

- Swap Calico for Cilium and compare (eBPF-native dataplane, Hubble
  observability).
- ~~Document a minor-version upgrade~~ — done, see
  [`Version-Upgrade.md`](./Version-Upgrade.md) (etcd snapshot, control
  plane before workers, one worker at a time, PDB-respecting drains).
- Automate `kubeadm init`/`join` via SSM Parameter Store instead of
  manual SSH, once the manual process is fully understood.

## Cost note

All instances run 24/7 unless stopped — `terraform destroy` when not
actively using the cluster, or stop instances manually (compute billing
stops; EBS storage still bills while stopped).
