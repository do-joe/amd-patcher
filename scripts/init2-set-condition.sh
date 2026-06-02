#!/usr/bin/env bash
# =============================================================================
# init container 2: set-condition  (UNPRIVILEGED)
# -----------------------------------------------------------------------------
# Runs ONLY after init 1 exits 0 (i.e. the patched driver is verified in dmesg
# after reboot). Sets the node condition AMDGPUDriverPatched=True, which the DO
# Node Readiness Controller watches; once True it removes the readiness taint.
#
# Identity / namespace boundary (per prompt):
#   * BINARY  : the HOST kubectl, mounted read-only into this container at
#               /host/usr/bin/kubectl via a hostPath volume. We exec it directly
#               (NO nsenter) so this container stays UNPRIVILEGED and the cred
#               files below remain resolvable in the CONTAINER filesystem.
#               (Host kubectl lives at /usr/bin/kubectl on this DOKS image, not
#                /usr/local/bin/kubectl.)
#   * IDENTITY: the POD ServiceAccount token + CA mounted by the kubelet at
#               /var/run/secrets/kubernetes.io/serviceaccount/ . Passed as
#               explicit flags so kubectl never discovers a host kubeconfig and
#               the call runs as the ClusterRole we granted.
# Idempotent: re-setting the condition to True is a no-op upsert (merge by type).
# =============================================================================
set -uo pipefail

KCTL="/host/usr/bin/kubectl"
SA_DIR="/var/run/secrets/kubernetes.io/serviceaccount"
TOKEN_FILE="${SA_DIR}/token"
CA_FILE="${SA_DIR}/ca.crt"
SERVER="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"
COND_TYPE="AMDGPUDriverPatched"

log() { echo "[init2 $(date -u +%FT%TZ)] $*"; }
die() { log "FATAL: $*"; exit 1; }

[ -x "${KCTL}" ]        || die "host kubectl not found/executable at ${KCTL}"
[ -r "${TOKEN_FILE}" ]  || die "SA token not readable at ${TOKEN_FILE}"
[ -r "${CA_FILE}" ]     || die "SA CA not readable at ${CA_FILE}"
[ -n "${NODE_NAME:-}" ] || die "NODE_NAME not set (downward API fieldRef spec.nodeName)"

TOKEN="$(cat "${TOKEN_FILE}")"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Strategic-merge patch on the status subresource. Node conditions merge by
# 'type', so this upserts our condition and preserves Ready/MemoryPressure/etc.
PATCH=$(cat <<JSON
{"status":{"conditions":[{"type":"${COND_TYPE}","status":"True","reason":"DriverPatchVerified","message":"amdgpu debug_print patch verified in dmesg after reboot","lastHeartbeatTime":"${TS}","lastTransitionTime":"${TS}"}]}}
JSON
)

kctl() {
  "${KCTL}" \
    --server="${SERVER}" \
    --token="${TOKEN}" \
    --certificate-authority="${CA_FILE}" \
    "$@"
}

log "Setting condition ${COND_TYPE}=True on node ${NODE_NAME} (server ${SERVER})."

attempt=0
until kctl patch node "${NODE_NAME}" --subresource=status --type=strategic -p "${PATCH}" 2>&1; do
  attempt=$((attempt+1))
  [ "${attempt}" -ge 5 ] && die "failed to patch node condition after ${attempt} attempts."
  log "patch attempt ${attempt} failed; retrying in 5s."
  sleep 5
done

log "Patch applied. Verifying condition is observable..."
STATUS="$(kctl get node "${NODE_NAME}" -o jsonpath="{.status.conditions[?(@.type=='${COND_TYPE}')].status}" 2>&1)"
[ "${STATUS}" = "True" ] || die "condition ${COND_TYPE} not observed True after patch (got '${STATUS}')."
log "Confirmed ${COND_TYPE}=True on node ${NODE_NAME}. Done."
exit 0
