# AMD GPU Driver Patcher — Customer Deployment Guide

Deploy the `amdgpu` kernel‑driver patch to a DigitalOcean Kubernetes (DOKS)
cluster of AMD GPU nodes.

> ## ⚠️ Before you deploy — two must‑dos
>
> **1 · This reboots every AMD GPU node.** Applying the DaemonSet patches and
> **reboots** each AMD GPU node once (every node added later is rebooted too).
> **Apply to the test cluster only**, in a planned maintenance window.
> → **[Reboot warning](#reboot-warning)**
>
> **2 · Update your GPU workloads to add a node selector.** Every GPU workload
> must set `nodeSelector: amd.com/gpu-driver-patched: "true"` so pods run **only
> on nodes whose kernel has already been patched and rebooted.** This is the
> gating step — without it, pods can land on an unpatched node.
> → **[Gate your workloads](#gate-workloads)**

---

## 1. What this deploys

A privileged DaemonSet that, on every AMD GPU node, installs the official
pre‑compiled `amdgpu` kernel modules, rebuilds the initramfs, reboots the node,
cryptographically verifies the patched driver loaded, and then labels the node
`amd.com/gpu-driver-patched=true`. A sample GPU workload uses that label to
schedule only onto patched nodes.

| Item | Value |
|------|-------|
| Container image | `ghcr.io/do-solutions/amdgpu-driver-patch:6.12.74-deb13-1-amd64` (also `:latest`) — **private (internal to the `do-solutions` org); pulling it requires the `ghcr-pull` image pull secret** |
| Target kernel | `6.12.74+deb13+1-amd64` (the image is kernel‑specific) |
| Node label written | `amd.com/gpu-driver-patched=true` |
| Image pull secret | `ghcr-pull` in the `kube-system` namespace |

### Repository links

- **Dockerfile** — [`Dockerfile`](https://github.com/do-joe/amd-patcher/blob/main/Dockerfile)
- **init container 1 (patch + reboot)** — [`scripts/init1-driver-patch.sh`](https://github.com/do-joe/amd-patcher/blob/main/scripts/init1-driver-patch.sh)
- **init container 2 (label node)** — [`scripts/init2-label-node.sh`](https://github.com/do-joe/amd-patcher/blob/main/scripts/init2-label-node.sh)
- **Label variant (primary)** — [`manifests/label/`](https://github.com/do-joe/amd-patcher/tree/main/manifests/label)
  - [`02-rbac.yaml`](https://github.com/do-joe/amd-patcher/blob/main/manifests/label/02-rbac.yaml)
  - [`03-daemonset.yaml`](https://github.com/do-joe/amd-patcher/blob/main/manifests/label/03-daemonset.yaml)
  - [`10-sample-deployment.yaml`](https://github.com/do-joe/amd-patcher/blob/main/manifests/label/10-sample-deployment.yaml)
- **NRC variant (for clusters with a Node Readiness Controller)** — [`manifests/nrc/`](https://github.com/do-joe/amd-patcher/tree/main/manifests/nrc)

### Download the manifests (no clone needed)

You don't need to clone this repo. Right‑click → **Save link as…** to download each
file, or `kubectl apply -f <url>` directly (this repo is public):

| Manifest | Download (raw) |
|----------|----------------|
| RBAC (ServiceAccount + ClusterRole) | [`02-rbac.yaml`](https://raw.githubusercontent.com/do-joe/amd-patcher/main/manifests/label/02-rbac.yaml) |
| DaemonSet (the patcher) | [`03-daemonset.yaml`](https://raw.githubusercontent.com/do-joe/amd-patcher/main/manifests/label/03-daemonset.yaml) |
| Sample GPU deployment | [`10-sample-deployment.yaml`](https://raw.githubusercontent.com/do-joe/amd-patcher/main/manifests/label/10-sample-deployment.yaml) |

---

## 2. What has already been done

- **The container image is built and published** to the GitHub Container
  Registry: `ghcr.io/do-solutions/amdgpu-driver-patch:6.12.74-deb13-1-amd64`
  (and `:latest`). The 4.3 MB patch payload is baked into the image, so nothing
  large needs to be committed to the repo. The package visibility is
  **internal** to the `do-solutions` org (not public).

- **The `ghcr-pull` image pull secret has been applied** to the `kube-system`
  namespace of the **test cluster** so the DaemonSet can pull the image.

  > ⏳ **This pull secret expires in 7 days — on 2026-06-12.** It is a
  > short‑lived GitHub token intended only for test deployment. **It will stop
  > working on June 12**, after which the DaemonSet can no longer pull the image
  > on new nodes. See [Production considerations](#5-production-considerations).

---

## 3. How it works

Each AMD GPU node runs one DaemonSet pod made of two run‑to‑completion init
containers plus an idle `pause` main container:

```
Pod on an AMD GPU node
├── init 1  "driver-patch"  (PRIVILEGED, hostPID)  ── patches + reboots
├── init 2  "label-node"    (unprivileged)         ── labels the node
└── main    "pause"                                 ── keeps the pod Running
```

### init 1 — patch and reboot (re‑entrant across the reboot)

All host changes are made inside the host namespaces via `nsenter -t 1`. The
script is a state machine that survives the reboot and re‑runs from the top when
the kubelet restarts the pod after boot:

1. **Kernel gate.** If the node's running kernel isn't exactly
   `6.12.74+deb13+1-amd64`, it refuses to do anything and crash‑loops (the
   pre‑compiled modules only load for that exact kernel). This is a safety stop,
   not a silent no‑op.
2. **First run on a fresh node:** extract the baked modules onto the host →
   verify every module against a build‑time **SHA‑256 manifest** → `depmod` →
   `update-initramfs` → record the boot ID → **reboot the node.**
3. **After the reboot:** the pod restarts, detects that the boot ID changed, and
   verifies the patched driver is actually live — (a) SHA‑256 of the on‑disk
   modules matches the baked payload, (b) `amdgpu` is loaded, and (c) the loaded
   module's `srcversion` matches the patched module on disk. Only then does it
   exit success, allowing init 2 to run.
4. If it patched and rebooted but verification still fails, it **crashes loudly
   for human review** rather than looping reboots.

### init 2 — gate the node with a label

After init 1 succeeds, init 2 uses the host `kubectl` with the pod's service
account to label the node `amd.com/gpu-driver-patched=true`. Workloads that
should run only on patched nodes set a matching `nodeSelector` (see the sample
deployment). This is **cooperative gating** — see the
[note in production considerations](#cooperative-gating).

### New nodes are patched automatically

Because this is a DaemonSet with a `doks.digitalocean.com/gpu-brand=amd` node
selector, **any AMD GPU node added to the cluster later is handled automatically**:

```
New AMD GPU node joins
        │
        ▼
DaemonSet schedules the patch pod  ──►  init 1 patches + reboots the node
        │                                        │
        │                                        ▼
        │                               node reboots, pod re‑runs, verifies
        ▼                                        │
node gets label amd.com/gpu-driver-patched=true ◄┘
        │
        ▼
GPU workloads (nodeSelector) schedule onto it
```

You do not need to re‑run anything when the cluster scales up — joining a node is
enough.

---

## 4. Deploying to the test cluster

> Run these against the **test cluster context only.** Confirm with
> `kubectl config current-context` first.

<a id="reboot-warning"></a>
### 4a. ⚠️ Reboot warning — apply to the test cluster ONLY

**Applying the DaemonSet reboots every AMD GPU node in the cluster.** Each node
is patched and then rebooted exactly once; thereafter the patch persists and the
node is not rebooted again. But the initial apply triggers a rolling set of node
reboots across the GPU pool, and **every newly added GPU node will also be
rebooted** as it is patched.

Because of this:

- **Only apply to the test cluster** until a production maintenance window is
  agreed with the customer.
- Drain / quiesce any GPU workloads you care about first — the nodes will go
  `NotReady` during the reboot.
- Do not apply to a production cluster casually. The reboot is unavoidable: the
  patched kernel modules only take effect after a reboot.

### 4b. Apply

1. **Pull secret.** It is already present on the test cluster's `kube-system`.
   To recreate it elsewhere, apply the exported `ghcr-pull-secret.yaml` (kept out
   of git) or create it imperatively:

   ```bash
   kubectl -n kube-system create secret docker-registry ghcr-pull \
     --docker-server=ghcr.io \
     --docker-username=<github-user> \
     --docker-password=<github-token> \
     --docker-email=<email>
   ```

2. **RBAC + DaemonSet** (this is the step that reboots the nodes). Apply the two
   manifests straight from their raw URLs — no clone required:

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/do-joe/amd-patcher/main/manifests/label/02-rbac.yaml \
                 -f https://raw.githubusercontent.com/do-joe/amd-patcher/main/manifests/label/03-daemonset.yaml
   ```

   (Or download them first via the [Download the manifests](#download-the-manifests-no-clone-needed)
   links and `kubectl apply -f ./02-rbac.yaml -f ./03-daemonset.yaml`.)

3. **Watch the patch + reboot cycle:**

   ```bash
   kubectl -n kube-system logs -f ds/amdgpu-driver-patch -c driver-patch
   kubectl get nodes -w        # nodes go NotReady -> Ready as they reboot
   ```

4. **Confirm a node is patched and labeled:**

   ```bash
   kubectl get node <node> \
     -o jsonpath='{.metadata.labels.amd\.com/gpu-driver-patched}'   # -> true
   ```

5. **(Optional) Prove a real GPU binds** with the sample workload:

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/do-joe/amd-patcher/main/manifests/label/10-sample-deployment.yaml
   kubectl get pods -o wide    # Running on a patched node, holding amd.com/gpu: 1
   ```

<a id="gate-workloads"></a>
### 4c. Gate your own GPU workloads with the node selector (required)

**This label is the gating mechanism, and it only works if your workloads opt
into it.** Every GPU workload you intend to run on this cluster **must** carry
the `amd.com/gpu-driver-patched: "true"` node selector. That is what guarantees a
pod is scheduled **only onto a node whose kernel driver has already been patched
and rebooted** — a node without the label has not finished patching, and pods
that omit the selector may land there and run against the unpatched driver.

Add this to the pod template of every Deployment / StatefulSet / Job / DaemonSet
that uses the GPU:

```yaml
spec:
  template:
    spec:
      nodeSelector:
        amd.com/gpu-driver-patched: "true"   # only schedule onto patched nodes
      tolerations:
        - key: amd.com/gpu                    # tolerate the AMD GPU device taint
          operator: Exists
          effect: NoSchedule
      containers:
        - name: <your-container>
          resources:
            limits:
              amd.com/gpu: 1                  # bind a real GPU via the device plugin
```

See [`manifests/label/10-sample-deployment.yaml`](https://github.com/do-joe/amd-patcher/blob/main/manifests/label/10-sample-deployment.yaml)
for a complete working example.

> **Why this matters:** gating here is *cooperative* — the patcher labels nodes,
> but it does not by itself stop a workload that omits the selector from being
> scheduled onto an unpatched node. The node selector on your workloads is the
> enforcement step. (For *hard* enforcement that does not rely on each workload
> opting in, use the [`manifests/nrc/`](https://github.com/do-joe/amd-patcher/tree/main/manifests/nrc)
> taint‑based variant instead — see [Cooperative gating](#cooperative-gating).)

---

## 5. Production considerations

This deployment is configured for **test** use. Before a production rollout on
the customer's cluster:

### Move the image to the customer's own registry (DOCR)

The image currently lives in our `do-solutions` GHCR org and is pulled with a
**short‑lived token that expires 2026-06-12.** For production it must be hosted
in the **customer's own DigitalOcean Container Registry (DOCR)** so it does not
depend on our org or a temporary token:

1. Push the image to the customer's DOCR (e.g.
   `registry.digitalocean.com/<customer-registry>/amdgpu-driver-patch:6.12.74-deb13-1-amd64`).
2. Grant the cluster registry access (DOKS integrates DOCR pull credentials
   natively, so a manual `ghcr-pull` secret is typically not needed).
3. Update the `image:` field in `manifests/label/03-daemonset.yaml` and remove
   the `imagePullSecrets: [{name: ghcr-pull}]` reference.

> The DigitalOcean **FDE** can help drive this DOCR migration and the production
> rollout planning.

### Cooperative gating

The label only *advertises* that a node is patched — it does not block a pod that
omits the `nodeSelector` from landing on an unpatched node. This is intentional
for the no‑NRC target. If hard enforcement is required, the
[`manifests/nrc/`](https://github.com/do-joe/amd-patcher/tree/main/manifests/nrc)
variant uses a Node Readiness Controller taint instead, or a self‑managed taint
can be added.

### Kernel coupling

The image is built for kernel `6.12.74+deb13+1-amd64` and **crash‑stops on any
other kernel.** A node‑pool kernel upgrade requires rebuilding the tarball and a
new kernel‑tagged image.

---

## 6. Verification checklist

| Check | Expected |
|-------|----------|
| DaemonSet ready | `kubectl -n kube-system get ds amdgpu-driver-patch` → DESIRED == READY |
| init 1 logs | kernel gate passes, `sha256 ... OK`, reboot, post‑reboot `Exiting 0` |
| Node label | `amd.com/gpu-driver-patched=true` on each AMD GPU node |
| Sample pod | `Running`, bound `amd.com/gpu: 1`, on a patched node |
| Scale‑up | a newly added GPU node auto‑patches, reboots, and gets the label |
