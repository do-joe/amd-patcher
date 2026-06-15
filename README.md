# AMD GPU Driver Patcher — Customer Deployment Guide

Deploy the `amdgpu` kernel‑driver patch to a DigitalOcean Kubernetes (DOKS)
cluster of AMD GPU nodes.

> ## ⚠️ Before you deploy — two must‑dos
>
> **1 · Patching is opt‑in per node — applying the manifests reboots nothing.**
> The DaemonSet schedules **only onto nodes you label**
> `amd.com/gpu-driver-patch-enabled=true`. Applying it to a live cluster is inert:
> no node is patched or rebooted until you opt it in. You then patch one node (or
> batch) at a time at your own pace, in a planned maintenance window.
> → **[Roll out per node](#reboot-warning)**
>
> **2 · Gate your GPU workloads with node affinity.** Every GPU workload must
> **require** `amd.com/gpu-driver-patched=true` via
> `requiredDuringSchedulingIgnoredDuringExecution` node affinity, so new pods run
> **only on nodes whose kernel has already been patched and rebooted** while pods
> already running are left untouched. This is the gating step — without it, pods
> can land on an unpatched node.
> → **[Gate your workloads](#gate-workloads)** · **[Migrate an existing cluster](#migrate-existing)**

---

## 1. What this deploys

A privileged DaemonSet that, on each AMD GPU node **you opt in** (by labeling it
`amd.com/gpu-driver-patch-enabled=true`), installs the official pre‑compiled
`amdgpu` kernel modules, rebuilds the initramfs, reboots the node,
cryptographically verifies the patched driver loaded, and then labels the node
`amd.com/gpu-driver-patched=true`. A sample GPU workload uses that label to
schedule only onto patched nodes.

| Item | Value |
|------|-------|
| Container image | `ghcr.io/do-solutions/amdgpu-driver-patch:6.12.74-deb13-1-amd64` (also `:latest`) — **private (internal to the `do-solutions` org); pulling it requires the `ghcr-pull` image pull secret** |
| Target kernel | `6.12.74+deb13+1-amd64` (the image is kernel‑specific) |
| Opt‑in label you set (the trigger) | `amd.com/gpu-driver-patch-enabled=true` — the DaemonSet patches **only** nodes carrying this |
| Node label written (the result) | `amd.com/gpu-driver-patched=true` — written after a verified patch; workloads gate on this |
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

Each **opted‑in** AMD GPU node (one labeled
`amd.com/gpu-driver-patch-enabled=true`) runs one DaemonSet pod made of two
run‑to‑completion init containers plus an idle `pause` main container. Nodes
without the opt‑in label get no pod and are never touched:

```
Pod on an opted‑in AMD GPU node
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

### New nodes are NOT patched automatically (opt‑in by design)

The DaemonSet's `nodeSelector` requires **both**
`doks.digitalocean.com/gpu-brand=amd` **and**
`amd.com/gpu-driver-patch-enabled=true`. A new AMD GPU node that joins **without**
the opt‑in label gets no patch pod and is left untouched — this is what makes it
safe to apply on a live cluster. Patching a node is a deliberate act:

```
You label a node: kubectl label node <node> amd.com/gpu-driver-patch-enabled=true
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

**Want a whole pool auto‑patched on scale‑up?** Set
`amd.com/gpu-driver-patch-enabled=true` as a **DOKS node‑pool label** — every node
that pool creates is born opted‑in and patches itself on join (scoped to the pools
you choose). Leave the label off a pool to keep its nodes under manual control.

---

## 4. Deploying

> Run these against the intended cluster context. Confirm with
> `kubectl config current-context` first.

<a id="reboot-warning"></a>
### 4a. How the opt‑in rollout works — no fleet‑wide reboot

**Applying the RBAC + DaemonSet reboots nothing.** The DaemonSet schedules only
onto nodes labeled `amd.com/gpu-driver-patch-enabled=true`, and at apply time no
node carries it — so the manifests sit inert and the cluster is undisturbed. This
is what makes it safe to apply to an **existing** cluster.

You then drive the rollout one node (or batch) at a time by adding the opt‑in
label. Each labeled node is patched and rebooted **exactly once**; thereafter the
patch persists and it is not rebooted again.

- **No big‑bang reboot:** nothing happens until you opt a node in, so you control
  the blast radius and timing.
- Before opting a node in, **drain / quiesce GPU workloads on it** — it goes
  `NotReady` during the single reboot.
- To pause or stop the rollout, simply leave the remaining nodes unlabeled.
  Removing the opt‑in label from an already‑patched node is safe: the patch
  persists on the host and its `amd.com/gpu-driver-patched=true` label stays; it
  only stops the (idle) pod from scheduling there.

### 4b. Apply, then opt in nodes one at a time

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

2. **RBAC + DaemonSet** (this reboots nothing — no node is opted in yet). Apply
   the two manifests straight from their raw URLs — no clone required:

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/do-joe/amd-patcher/main/manifests/label/02-rbac.yaml \
                 -f https://raw.githubusercontent.com/do-joe/amd-patcher/main/manifests/label/03-daemonset.yaml
   ```

   (Or download them first via the [Download the manifests](#download-the-manifests-no-clone-needed)
   links and `kubectl apply -f ./02-rbac.yaml -f ./03-daemonset.yaml`.)

   Confirm it is inert — the DaemonSet should show `DESIRED 0`, and no patch pod
   should exist yet:

   ```bash
   kubectl -n kube-system get ds amdgpu-driver-patch     # DESIRED == 0
   ```

3. **Opt in a node to trigger its patch + reboot.** Pick one AMD GPU node and
   label it; the DaemonSet immediately schedules a patch pod onto **that node
   only**:

   ```bash
   kubectl label node <node> amd.com/gpu-driver-patch-enabled=true
   ```

4. **Watch that node's patch + reboot cycle:**

   ```bash
   kubectl -n kube-system logs -f ds/amdgpu-driver-patch -c driver-patch
   kubectl get node <node> -w        # goes NotReady -> Ready across the reboot
   ```

5. **Confirm the node is patched and labeled, then repeat for the next node:**

   ```bash
   kubectl get node <node> \
     -o jsonpath='{.metadata.labels.amd\.com/gpu-driver-patched}'   # -> true
   ```

   Re‑run step 3 for each additional node (or batch several labels together) at
   whatever pace your maintenance window allows.

6. **(Optional) Prove a real GPU binds** with the sample workload:

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/do-joe/amd-patcher/main/manifests/label/10-sample-deployment.yaml
   kubectl get pods -o wide    # Running on a patched node, holding amd.com/gpu: 1
   ```

<a id="gate-workloads"></a>
### 4c. Gate your own GPU workloads with node affinity (required)

**This label is the gating mechanism, and it only works if your workloads opt
into it.** Every GPU workload you intend to run on this cluster **must** require
the `amd.com/gpu-driver-patched=true` label via **node affinity**. That is what
guarantees a pod is scheduled **only onto a node whose kernel driver has already
been patched and rebooted** — a node without the label has not finished patching,
and pods that omit the gate may land there and run against the unpatched driver.

Use `requiredDuringSchedulingIgnoredDuringExecution` rather than a plain
`nodeSelector`. The two are the same scheduling constraint, but the affinity form
makes the migration‑safe behavior explicit:

- **`IgnoredDuringExecution`** — adding this gate to a Deployment that is **already
  running on unpatched nodes does not evict those pods.** They keep running; the
  rule only governs where *new* pods may be placed. This is what lets you roll the
  gate out across a live cluster before any node is patched.
- **`required…Scheduling`** — a **new** pod can be placed **only** on a patched
  node. If none has free capacity it stays `Pending` until one does (expected
  during the migration window — see [Migrating an existing cluster](#migrate-existing)).

Add this to the pod template of every Deployment / StatefulSet / Job / DaemonSet
that uses the GPU:

```yaml
spec:
  template:
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: amd.com/gpu-driver-patched   # only patched nodes
                    operator: In
                    values: ["true"]
```

See [`manifests/label/10-sample-deployment.yaml`](https://github.com/do-joe/amd-patcher/blob/main/manifests/label/10-sample-deployment.yaml)
for a complete working example.

> **Why this matters:** gating here is *cooperative* — the patcher labels nodes,
> but it does not by itself stop a workload that omits the affinity from being
> scheduled onto an unpatched node. The node affinity on your workloads is the
> enforcement step. (For *hard* enforcement that does not rely on each workload
> opting in, use the [`manifests/nrc/`](https://github.com/do-joe/amd-patcher/tree/main/manifests/nrc)
> taint‑based variant instead — see [Cooperative gating](#cooperative-gating).)

<a id="migrate-existing"></a>
### 4d. Migrating an existing cluster, batch by batch

Because both the patcher (opt‑in label) and your workloads (node affinity) are
gated, you can migrate a **live** cluster onto patched nodes without a fleet‑wide
reboot and without evicting running pods. The order matters:

1. **Gate your GPU workloads first** with the [4c](#gate-workloads) affinity (and
   `maxUnavailable: 0`). Pods already running on unpatched nodes keep running
   (`IgnoredDuringExecution`); only *new* pods now require a patched node.
2. **Apply the RBAC + DaemonSet** ([4b](#reboot-warning) steps 1–2). Still inert —
   no node is labeled, so nothing is patched or rebooted.
3. **Migrate one batch of nodes at a time.** For each node in the batch:

   ```bash
   # a. cordon + evict workloads (the patcher DaemonSet is left in place)
   kubectl drain <node> --ignore-daemonsets --delete-emptydir-data

   # b. opt the node in -> patcher schedules onto it, patches, and reboots it
   kubectl label node <node> amd.com/gpu-driver-patch-enabled=true

   # c. wait until the patch is verified (label appears after the reboot)
   kubectl get node <node> \
     -o jsonpath='{.metadata.labels.amd\.com/gpu-driver-patched}'   # -> true

   # d. return the node to service -> gated workloads reschedule onto it
   kubectl uncordon <node>
   ```

   Then repeat for the next batch until every GPU node is patched.

> **Pending pods are expected mid‑batch.** Between drain (a) and uncordon (d) a
> drained GPU pod has no patched node to land on, so it waits `Pending` — the hard
> gate working as intended during the reboot. For the **first** batch there is no
> patched capacity yet, so its pods stay `Pending` until step (c)/(d) completes;
> later batches can also reschedule onto nodes patched in earlier batches.

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
| Inert on apply | before any node is labeled, `kubectl -n kube-system get ds amdgpu-driver-patch` → DESIRED == 0, no patch pod, no reboots |
| Un‑opted‑in node untouched | a node without `amd.com/gpu-driver-patch-enabled=true` gets no pod and never reboots |
| Opt‑in triggers patch | after `kubectl label node <node> amd.com/gpu-driver-patch-enabled=true`, a patch pod schedules on that node only |
| DaemonSet ready | once nodes are opted in, `kubectl -n kube-system get ds amdgpu-driver-patch` → DESIRED == READY (== number of opted‑in nodes) |
| init 1 logs | kernel gate passes, `sha256 ... OK`, reboot, post‑reboot `Exiting 0` |
| Node label | `amd.com/gpu-driver-patched=true` on each opted‑in node after its patch |
| Workload gate is non‑disruptive | adding the 4c node affinity to a Deployment running on unpatched nodes does **not** evict its pods; a **new** pod stays `Pending` until at least one node has `amd.com/gpu-driver-patched=true` |
| Sample pod | `Running`, bound `amd.com/gpu: 1`, on a patched node |
| Pool scale‑up | a new node in a pool labeled `amd.com/gpu-driver-patch-enabled=true` auto‑patches, reboots, and gets the `-patched` label; a node without it stays untouched |
