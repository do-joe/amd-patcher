#!/usr/bin/env bash
# =============================================================================
# init container 1: driver-patch  (PRIVILEGED, hostPID)
# -----------------------------------------------------------------------------
# Installs the OFFICIAL amdgpu patch — a set of PRE-COMPILED .ko.xz modules baked
# into this image — onto the host, rebuilds the initramfs, and reboots. There is
# NO source build (no dkms) and NO dmesg signal string. Verification is instead
# cryptographic: a sha256 manifest generated from the SAME baked tarball at image
# build time (/opt/amdgpu-patch/manifest.sha256) is the oracle.
#
# All host mutations run inside the host namespaces via `nsenter -t 1 ...`.
# Everything keys off `uname -r` (the modules only load for that exact
# /lib/modules/<krel> dir), never a dkms version.
#
# Exit-code contract:
#   * Exit 0   -> ONLY post-reboot, when verify_installed_and_loaded passes. This
#                 is the only path that lets init 2 run (label / set-condition).
#   * Reboot   -> the deliberate mid-flow step. The node goes down, the pod is
#                 killed, the kubelet restarts the init sequence after boot. We
#                 never exit 0 here: we trigger reboot then `sleep infinity` (the
#                 node going down ends the process; no fail-closed timeout, so a
#                 slow-but-legitimate reboot never produces a spurious crash).
#   * Exit !=0 -> kernel mismatch, missing tool, extraction failure, sha256
#                 mismatch, or (post-reboot) verify still failing. The pod shows
#                 Init:CrashLoopBackOff; the node stays gated for human review.
#
# State machine (re-entrant across the reboot, evaluated top-to-bottom):
#   Gate 0  host kernel must equal EXPECT_KREL, and host must have tar + xz.
#   Step A  APPLIED present + boot_id changed + verify passes -> exit 0 (success).
#   Step B  APPLIED present + boot_id changed + verify FAILS   -> die (human
#           review; no reboot, no re-extract -> prevents reboot loops).
#   Step C  otherwise (fresh node) -> extract + sha256 verify + depmod +
#           initramfs + marker + reboot.
# =============================================================================
set -uo pipefail

PAYLOAD="/opt/amdgpu-patch/dkms_patch.tar.gz"   # baked tarball (container fs)
MANIFEST="/opt/amdgpu-patch/manifest.sha256"    # build-time oracle (container fs)
EXPECT_KREL="6.12.74+deb13+1-amd64"             # tarball's hardcoded kernel dir
MARKER_DIR="/var/lib/amdgpu-patch"              # host fs, PERSISTS across reboot
APPLIED="${MARKER_DIR}/applied"
BOOTID_FILE="${MARKER_DIR}/reboot-boot-id"
DKMS_DIR="/lib/modules/${EXPECT_KREL}/updates/dkms"
PEERING_SCRIPT="/var/lib/cloud/scripts/peering.sh"  # host fs; re-adds VPC peering routes lost on reboot

# The 8 modules the official tarball delivers (presence sanity check).
EXPECT_MODULES=(
  amd-sched.ko.xz
  amddrm_buddy.ko.xz
  amddrm_exec.ko.xz
  amddrm_ttm_helper.ko.xz
  amdgpu.ko.xz
  amdkcl.ko.xz
  amdttm.ko.xz
  amdxcp.ko.xz
)

log()  { echo "[init1 $(date -u +%FT%TZ)] $*"; }
die()  { log "FATAL: $*"; exit 1; }

# Run a shell command string inside the host namespaces (host PID 1).
hsh()  { nsenter -t 1 -m -u -i -n -p -- bash -c "$1"; }

# Read the running kernel's boot id from the host (changes on every reboot).
host_boot_id() { hsh "cat /proc/sys/kernel/random/boot_id 2>/dev/null" | tr -d '[:space:]'; }

# ---------------------------------------------------------------------------
# Re-add VPC peering routes lost across the reboot. The reboot in Step C drops
# the dynamically-added peering routes; the node comes back up without them, so
# we re-run the host's own peering script in the post-reboot phase. Best-effort:
# a missing script or a non-zero exit is logged loudly but does NOT crash init1
# — a routing hiccup must not block node labeling or strand the node unpatched.
# ---------------------------------------------------------------------------
restore_peering_routes() {
  if ! hsh "test -x '${PEERING_SCRIPT}'"; then
    log "WARN: peering script ${PEERING_SCRIPT} not found/executable on host; skipping route restore."
    return 0
  fi
  log "Re-adding VPC peering routes via host ${PEERING_SCRIPT} ..."
  if hsh "${PEERING_SCRIPT} 2>&1"; then
    log "Peering routes restored (${PEERING_SCRIPT} exited 0)."
  else
    log "WARN: ${PEERING_SCRIPT} exited non-zero; VPC peering routes may be missing. Continuing."
  fi
}

# ---------------------------------------------------------------------------
# Post-reboot verification oracle (no dmesg). Require ALL three:
#   1. sha256 manifest match of the installed .ko.xz on disk (cryptographic
#      proof the exact patched bytes are present).
#   2. `lsmod` shows amdgpu loaded.
#   3. the LOADED module's srcversion == the on-disk patched amdgpu.ko.xz's
#      srcversion (proves the running module IS the patched one, since
#      updates/dkms takes precedence after depmod). The loaded module's
#      srcversion is authoritatively exposed at /sys/module/amdgpu/srcversion.
# ---------------------------------------------------------------------------
verify_installed_and_loaded() {
  # 1. cryptographic on-disk proof. Manifest paths are relative to /, so cd /.
  if ! cat "${MANIFEST}" | nsenter -t 1 -m -- bash -c 'cd / && sha256sum -c - >/dev/null 2>&1'; then
    log "verify: sha256 manifest check FAILED (on-disk modules != baked payload)."
    return 1
  fi
  # 2. module loaded
  if ! hsh "lsmod | grep -q '^amdgpu '"; then
    log "verify: amdgpu is NOT loaded (lsmod)."
    return 1
  fi
  # 3. loaded module == patched on-disk module (srcversion)
  local loaded disk
  loaded="$(hsh 'cat /sys/module/amdgpu/srcversion 2>/dev/null' | tr -d '[:space:]')"
  disk="$(hsh "modinfo -F srcversion '${DKMS_DIR}/amdgpu.ko.xz' 2>/dev/null" | tr -d '[:space:]')"
  if [ -z "${loaded}" ] || [ -z "${disk}" ]; then
    log "verify: could not read srcversion (loaded='${loaded}' disk='${disk}')."
    return 1
  fi
  if [ "${loaded}" != "${disk}" ]; then
    log "verify: loaded srcversion (${loaded}) != on-disk patched srcversion (${disk})."
    return 1
  fi
  log "verify: sha256 OK + amdgpu loaded + srcversion match (${loaded})."
  return 0
}

log "amdgpu driver-patch init starting (expect kernel ${EXPECT_KREL})."

# ---------------------------------------------------------------------------
# Gate 0 — kernel match + host toolchain. Mismatch => crash. The modules only
# load for /lib/modules/${EXPECT_KREL}; on any other kernel an install would be a
# silent no-op, so we refuse rather than mislabel the node as patched.
# ---------------------------------------------------------------------------
HOST_KREL="$(hsh 'uname -r' | tr -d '[:space:]')"
[ -n "${HOST_KREL}" ] || die "could not read host kernel release."
if [ "${HOST_KREL}" != "${EXPECT_KREL}" ]; then
  die "kernel gate: host runs '${HOST_KREL}' but this image's payload targets '${EXPECT_KREL}'. Refusing to patch (a new kernel needs a new tarball + image)."
fi
hsh "command -v tar >/dev/null 2>&1" || die "kernel gate: host has no 'tar'."
hsh "command -v xz  >/dev/null 2>&1" || die "kernel gate: host has no 'xz' (needed to read .ko.xz)."
[ -f "${PAYLOAD}" ]  || die "baked payload ${PAYLOAD} missing from image."
[ -f "${MANIFEST}" ] || die "baked manifest ${MANIFEST} missing from image."
log "Kernel gate passed: host kernel ${HOST_KREL} == ${EXPECT_KREL}; tar + xz present."

CUR_BOOT_ID="$(host_boot_id)"
[ -n "${CUR_BOOT_ID}" ] || die "could not read host boot_id."

# ---------------------------------------------------------------------------
# Determine reboot state. APPLIED + a recorded boot_id that DIFFERS from the
# current one means we applied AND have since rebooted.
# ---------------------------------------------------------------------------
APPLIED_PRESENT=1; hsh "test -f '${APPLIED}'" || APPLIED_PRESENT=0
RECORDED_BOOT_ID="$(hsh "cat '${BOOTID_FILE}' 2>/dev/null" | tr -d '[:space:]')"
REBOOTED=0
if [ "${APPLIED_PRESENT}" -eq 1 ] && [ -n "${RECORDED_BOOT_ID}" ] && [ "${RECORDED_BOOT_ID}" != "${CUR_BOOT_ID}" ]; then
  REBOOTED=1
fi
log "State: applied=${APPLIED_PRESENT} rebooted=${REBOOTED} (boot_id cur=${CUR_BOOT_ID} recorded=${RECORDED_BOOT_ID:-<none>})."

# ---------------------------------------------------------------------------
# Step A — success branch: applied, rebooted, and verification passes.
# ---------------------------------------------------------------------------
if [ "${REBOOTED}" -eq 1 ]; then
  # The reboot wiped the node's VPC peering routes; re-add them now that the
  # node is back up, before anything else in the post-reboot phase.
  restore_peering_routes
  if verify_installed_and_loaded; then
    log "Patched driver verified after reboot. Exiting 0 (init 2 may run)."
    exit 0
  fi
  # -------------------------------------------------------------------------
  # Step B — applied + rebooted but verify still fails. Genuine failure: crash
  # loudly for human review. Do NOT reboot, do NOT re-extract (that would be a
  # silent reboot loop, the opposite of the design's intent).
  # -------------------------------------------------------------------------
  log "---- lsmod | grep amdgpu ----"; hsh "lsmod | grep -i amdgpu" || true
  log "---- installed modules ----";   hsh "ls -l '${DKMS_DIR}' 2>&1" || true
  die "applied + rebooted, but verification still fails. Crashing for human review (no reboot, no re-extract)."
fi

# ---------------------------------------------------------------------------
# Step C — fresh node (or applied-but-not-yet-rebooted): full install + reboot.
# Any failure => crash (exit non-zero).
# ---------------------------------------------------------------------------
log "Fresh node: installing pre-compiled amdgpu modules."

# 1. Extract the baked tarball onto host /. The archive holds relative
#    'lib/modules/<krel>/...' paths, so -C / lands them at the right host dirs.
log "Extracting ${PAYLOAD} onto host / ..."
if ! cat "${PAYLOAD}" | nsenter -t 1 -m -- tar -xzf - -C /; then
  die "extraction failed (tar -xzf onto host /)."
fi

# 2. Presence sanity check: all 8 expected modules must now exist on the host.
for m in "${EXPECT_MODULES[@]}"; do
  hsh "test -f '${DKMS_DIR}/${m}'" || die "expected module ${DKMS_DIR}/${m} missing after extraction."
done
log "All ${#EXPECT_MODULES[@]} expected modules present in ${DKMS_DIR}."

# 3. Integrity check (deterministic, replaces dmesg): stream the build-time
#    manifest to the host and verify every line is OK. Manifest paths are
#    relative to /, so we cd / on the host before checking.
log "Verifying sha256 manifest against on-disk modules ..."
if ! cat "${MANIFEST}" | nsenter -t 1 -m -- bash -c 'cd / && sha256sum -c -'; then
  die "sha256 integrity check FAILED: extracted modules do not match the baked manifest."
fi
log "sha256 manifest verified: on-disk modules match the baked payload exactly."

# 4. Rebuild module dependency data so updates/dkms takes precedence on load.
log "depmod -a ${EXPECT_KREL} ..."
hsh "depmod -a '${EXPECT_KREL}' 2>&1" || die "depmod failed."

# 5. Record the current boot_id BEFORE rebooting. After the reboot the host
#    boot_id changes, which is how the next run detects 'rebooted'.
hsh "mkdir -p '${MARKER_DIR}'" || die "could not create ${MARKER_DIR}."
printf '%s\n' "${CUR_BOOT_ID}" | nsenter -t 1 -m -- tee "${BOOTID_FILE}" >/dev/null \
  || die "could not record boot_id to ${BOOTID_FILE}."
log "Recorded pre-reboot boot_id ${CUR_BOOT_ID} to ${BOOTID_FILE}."

# 6. Rebuild the initramfs for the target kernel (matches apply-patch.txt).
log "update-initramfs -c -k ${EXPECT_KREL} ..."
hsh "update-initramfs -c -k '${EXPECT_KREL}' 2>&1" || die "update-initramfs failed."

# 7. Drop the APPLIED marker (so a pod kill before reboot still lands sanely).
hsh "touch '${APPLIED}'" || die "could not write marker ${APPLIED}."
log "Marker ${APPLIED} written."

# 8. Reboot to load the patched modules. Node goes down, init re-runs after boot.
log "Triggering host reboot to load the patched amdgpu driver."
hsh "reboot" || die "reboot command failed."
log "Reboot triggered; sleeping until the node goes down. Will NOT exit 0 here."
# sleep infinity (not a bounded timeout): the node going down ends this process.
sleep infinity
