# Kubeadm Kubernetes Cluster Upgrade: v1.35 → v1.36

Manual, step-by-step upgrade of the kubeadm-ec2-lab cluster from v1.35.8 to
v1.36.4, following the kubeadm-recommended order: control plane first, then
workers one at a time. No automation — every command run and verified by
hand, consistent with the rest of this lab.

## Versions in play

| Component      | Current   | Target   |
|-----------------|-----------|----------|
| kubeadm/kubelet/kubectl | v1.35.8   | v1.36.4  |
| etcd            | 3.6.6-0   | 3.6.8-0  |
| CoreDNS         | v1.13.1   | v1.14.2  |
| kube-proxy      | 1.35.8    | v1.36.4  |

Note: `kubeadm upgrade plan` reported v1.37.0 as available upstream but fell
back to the latest 1.36 patch (`stable-1.36`) since kubeadm only supports
upgrading one minor version at a time. Don't skip from 1.35 straight to
1.37 — go 1.35 → 1.36 → 1.37 if you continue upgrading later.

## Pre-upgrade checklist

- [ ] `kubectl get nodes` — confirm all nodes `Ready` before starting
- [ ] `kubectl get pods -A` — confirm nothing unexpectedly unhealthy
- [ ] Snapshot etcd (control plane only, single-member — this is your only
      rollback path if `kubeadm upgrade apply` goes wrong):
  ```bash
  sudo ETCDCTL_API=3 etcdctl snapshot save /root/etcd-backup-$(date +%F).db \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key
  ```
- [ ] Note current PDB (`nginx-test-pdb`, `minAvailable: 5`) — the worker
      drains below must respect it
- [ ] Have a rollback plan in mind: with a single etcd member there is no
      live failover if the control plane upgrade fails mid-way — the etcd
      snapshot above is what you'd restore from

---

## Control-Plane Upgrade

### Step 1: Point APT to the v1.36 repo

```bash
pager /etc/apt/sources.list.d/kubernetes.list

sudo vim /etc/apt/sources.list.d/kubernetes.list
```

Final line should be exactly:

```
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /
```

Remove any legacy `apt.kubernetes.io` entries to avoid mixing repos, then
refresh indexes:

```bash
sudo apt-get update
```

### Step 2: Determine the exact target version

```bash
sudo apt-get update
sudo apt-cache madison kubeadm
```

```
kubeadm | 1.36.4-1.1 | https://pkgs.k8s.io/core:/stable:/v1.36/deb  Packages
kubeadm | 1.36.3-1.1 | https://pkgs.k8s.io/core:/stable:/v1.36/deb  Packages
kubeadm | 1.36.2-2.1 | https://pkgs.k8s.io/core:/stable:/v1.36/deb  Packages
kubeadm | 1.36.1-1.1 | https://pkgs.k8s.io/core:/stable:/v1.36/deb  Packages
kubeadm | 1.36.0-1.1 | https://pkgs.k8s.io/core:/stable:/v1.36/deb  Packages
```

Target: `1.36.4-1.1`. If 1.36 doesn't show up here, re-check the repo file
from Step 1 and re-run `apt-get update`.

### Step 3: Upgrade kubeadm (control plane)

```bash
sudo apt-mark unhold kubeadm
sudo apt-get update && sudo apt-get install -y kubeadm=1.36.4-1.1
sudo apt-mark hold kubeadm
kubeadm version   # should report v1.36.4
```

Unhold → install exact version → hold prevents drift during and after the
maintenance window.

Optional — pre-pull images to reduce restart lag:

```bash
sudo kubeadm config images pull
```

### Step 4: Plan the upgrade (dry-run)

```bash
sudo kubeadm upgrade plan   # think "terraform plan" for kubeadm
```

Expected output:

```
[upgrade/versions] Cluster version: 1.35.8
[upgrade/versions] kubeadm version: v1.36.4
[upgrade/versions] Target version: v1.36.4
[upgrade/versions] Latest version in the v1.35 series: v1.35.8

Components that must be upgraded manually after you have upgraded the control plane with 'kubeadm upgrade apply':
COMPONENT   NODE                        CURRENT   TARGET
kubelet     kubeadm-lab-control-plane   v1.35.8   v1.36.4
kubelet     kubeadm-lab-worker-1        v1.35.8   v1.36.4
kubelet     kubeadm-lab-worker-2        v1.35.8   v1.36.4

Upgrade to the latest stable version:

COMPONENT                 NODE                        CURRENT   TARGET
kube-apiserver            kubeadm-lab-control-plane   v1.35.8   v1.36.4
kube-controller-manager   kubeadm-lab-control-plane   v1.35.8   v1.36.4
kube-scheduler            kubeadm-lab-control-plane   v1.35.8   v1.36.4
kube-proxy                                            1.35.8    v1.36.4
CoreDNS                                               v1.13.1   v1.14.2
etcd                      kubeadm-lab-control-plane   3.6.6-0   3.6.8-0
```

Optional — see manifest diffs before applying:

```bash
sudo kubeadm upgrade diff v1.36.4
```

### Step 5: Apply the control-plane upgrade

```bash
sudo kubeadm upgrade apply v1.36.4
```

Expected tail of output:

```
[upgrade] SUCCESS! A control plane node of your cluster was upgraded to "v1.36.4".
[upgrade] Now please proceed with upgrading the rest of the nodes by following the right order.
```

Notes:
- `kubeadm upgrade apply` rewrites the static pod manifests (image tags,
  flags) for the control-plane components; kubelet then restarts each one
  with the new image. Expect a brief API-server blip while this happens —
  this is separate from, and expected alongside, any worker-drain downtime
  you're testing against the `nginx-test` Service.
- Certificates managed by kubeadm are renewed automatically during this
  step. To opt out: `--certificate-renewal=false`.

### Step 6: Verify server version and node skew

```bash
kubectl version
# Client Version: v1.35.8
# Server  Version: v1.36.4  ← control plane upgraded, node kubelets still 1.35.8

kubectl get nodes
# control-plane still shows VERSION v1.35.8 in the kubelet column until Step 7
```

### Step 7: Upgrade node-local bits on the control-plane node

```bash
sudo apt-mark unhold kubelet kubectl || true
sudo apt-get install -y kubelet=1.36.4-1.1 kubectl=1.36.4-1.1
sudo systemctl daemon-reload && sudo systemctl restart kubelet
sudo apt-mark hold kubeadm kubelet kubectl
```

Confirm:

```bash
kubectl get nodes
# control-plane should now show VERSION v1.36.4
```

---

## Worker Node Upgrades (one at a time)

Repeat this whole section per worker — never drain more than one node at
once, and don't start the next worker until the previous one is
`Ready`/`Schedulable` again.

### Step 1: Cordon, then drain (from control plane or any admin shell)

```bash
# Cordon: stop new pods from scheduling on this node
kubectl cordon worker-1

# Inspect what's running here before you evict it
kubectl get pods -A -o wide | grep worker-1

# Drain: evict existing pods, respecting PodDisruptionBudgets (DaemonSets ignored)
kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=10m
```

`kubectl drain` cordons automatically before evicting, but cordoning first
is safer — it stops new pods from landing while you review impact, check
PDBs, let anything long-lived finish, and gives you a clean way to back out
(`kubectl uncordon`) if you need to postpone.

With `nginx-test-pdb` set to `minAvailable: 5` out of 10 replicas, the
drain will block if evicting a pod would drop available replicas below 5 —
watch for `Cannot evict pod as it would violate the pod's disruption
budget` if that happens, and hold off until enough replacements are
`Ready` elsewhere.

### Step 2: Upgrade the worker (on the worker node)

```bash
# Ensure the repo is already set to v1.36 (same as control-plane)
sudo vim /etc/apt/sources.list.d/kubernetes.list
# deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /

sudo apt-mark unhold kubeadm kubelet kubectl
sudo apt-get update
sudo apt-get install -y kubeadm=1.36.4-1.1
sudo kubeadm upgrade node
sudo apt-get install -y kubelet=1.36.4-1.1 kubectl=1.36.4-1.1
sudo systemctl daemon-reload && sudo systemctl restart kubelet
sudo apt-mark hold kubeadm kubelet kubectl
```

`kubeadm upgrade node` on a worker updates its local kubelet config and, if
applicable, kube-proxy — there's no static-pod control-plane manifest to
touch here, unlike Step 5 on the control plane.

### Step 3: Uncordon and verify (from admin shell)

```bash
kubectl uncordon worker-1
kubectl get nodes -o wide
```

Confirm `worker-1` shows `Ready`, `Schedulable`, and `VERSION v1.36.4`
before moving to the next node.

**Repeat Steps 1–3 for `worker-2` (and any others), one at a time.**

---

## Post-upgrade

- [ ] `kubectl get nodes -o wide` — all nodes `Ready`, all showing `v1.36.4`
- [ ] `kubectl get pods -A` — nothing crash-looping, CoreDNS pods healthy on
      the new version
- [ ] `kubectl get pods -l app=nginx-test -o wide` — 10/10 `Running`,
      spread across workers again post-drain
- [ ] Confirm the `curl` loop against the NodePort showed no non-200
      responses throughout both the control-plane apply and each worker
      drain
- [ ] **Controlled reboot of each node**, one at a time (control plane
      last), after all package/component changes above. A reboot applies
      any pending kernel/module changes, gives a clean baseline, and rules
      out a stale pending-reboot state confusing root cause on the *next*
      piece of maintenance. Cordon/drain/uncordon around each reboot the
      same as the upgrade itself.
- [ ] Snapshot etcd again post-upgrade as a new baseline

## Rollback notes

- kubeadm does not support downgrading a live cluster. If `kubeadm upgrade
  apply` fails partway on the control plane, the etcd snapshot taken in
  the pre-upgrade checklist is the recovery path (restore, then re-init
  against the restored data — this is a destructive, from-scratch
  recovery on a single-control-plane cluster like this one).
- If a single worker's upgrade goes wrong, it's simpler: leave it
  cordoned, `kubeadm reset` that node, and rejoin it fresh at the new
  version rather than trying to fix it in place.

## Next steps

- Repeat this same process for the 1.36 → 1.37 hop once 1.37 stabilizes.
- Consider scripting the worker-upgrade loop (cordon → upgrade → uncordon
  → wait for Ready) once the manual sequence above is second nature.