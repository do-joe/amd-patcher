#!/usr/bin/env bash
# =============================================================================
# init container 2: label-node  (UNPRIVILEGED)  — LABEL variant (no NRC)
# -----------------------------------------------------------------------------
# Runs ONLY after init 1 exits 0 (i.e. the patched driver is installed, loaded,
# and cryptographically verified after reboot). Labels the node
# amd.com/gpu-driver-patched=true. A sample workload gates on that label via a
# nodeSelector — cooperative gating, since this target cluster has no Node
# Readiness Controller to manage a taint.
#
# Identity / namespace boundary (same model as init2-set-condition.sh):
#   * BINARY  : the HOST kubectl, mounted read-only at /host/usr/bin/kubectl via
#               a hostPath volume. Exec'd directly (NO nsenter) so this container
#               stays UNPRIVILEGED and the cred files below resolve in the
#               CONTAINER filesystem. (Host kubectl is /usr/bin/kubectl on DOKS.)
#   * IDENTITY: the POD ServiceAccount token + CA mounted by the kubelet at
#               /var/run/secrets/kubernetes.io/serviceaccount/, passed as explicit
#               flags so kubectl never discovers a host kubeconfig.
# Idempotent: --overwrite makes re-labeling a no-op upsert.
# =============================================================================
set -uo pipefail

KCTL="/host/usr/bin/kubectl"
SA_DIR="/var/run/secrets/kubernetes.io/serviceaccount"
TOKEN_FILE="${SA_DIR}/token"
CA_FILE="${SA_DIR}/ca.crt"
SERVER="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"
LABEL_KEY="amd.com/gpu-driver-patched"
LABEL_VAL="true"

log() { echo "[init2 $(date -u +%FT%TZ)] $*"; }
die() { log "FATAL: $*"; exit 1; }

[ -x "${KCTL}" ]        || die "host kubectl not found/executable at ${KCTL}"
[ -r "${TOKEN_FILE}" ]  || die "SA token not readable at ${TOKEN_FILE}"
[ -r "${CA_FILE}" ]     || die "SA CA not readable at ${CA_FILE}"
[ -n "${NODE_NAME:-}" ] || die "NODE_NAME not set (downward API fieldRef spec.nodeName)"

TOKEN="$(cat "${TOKEN_FILE}")"

kctl() {
  "${KCTL}" \
    --server="${SERVER}" \
    --token="${TOKEN}" \
    --certificate-authority="${CA_FILE}" \
    "$@"
}

log "Labeling node ${NODE_NAME} with ${LABEL_KEY}=${LABEL_VAL} (server ${SERVER})."

attempt=0
until kctl label node "${NODE_NAME}" "${LABEL_KEY}=${LABEL_VAL}" --overwrite 2>&1; do
  attempt=$((attempt+1))
  [ "${attempt}" -ge 5 ] && die "failed to label node after ${attempt} attempts."
  log "label attempt ${attempt} failed; retrying in 5s."
  sleep 5
done

log "Label applied. Verifying it is observable..."
VAL="$(kctl get node "${NODE_NAME}" -o jsonpath="{.metadata.labels.amd\.com/gpu-driver-patched}" 2>&1)"
[ "${VAL}" = "${LABEL_VAL}" ] || die "label ${LABEL_KEY} not observed '${LABEL_VAL}' after patch (got '${VAL}')."
log "Confirmed ${LABEL_KEY}=${LABEL_VAL} on node ${NODE_NAME}. Done."
exit 0
