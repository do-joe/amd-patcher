# =============================================================================
# amdgpu-driver-patch image
# -----------------------------------------------------------------------------
# Ships the pre-compiled amdgpu .ko.xz kernel modules (the official patch) baked
# in, plus the init scripts. The 4.3 MB tarball is kernel-specific, so the image
# is tagged by kernel release. init1 extracts the payload onto the host and
# verifies it against manifest.sha256 — an oracle derived from the SAME baked
# tarball at build time, so it can never drift from the payload it checks.
#
# Debian 13 (trixie) matches the DOKS node OS. We bake no kubectl: init2 uses the
# host kubectl via a hostPath mount.
# =============================================================================
FROM debian:trixie-slim

LABEL org.opencontainers.image.source=https://github.com/do-solutions/amd-patcher

# Kernel release the baked modules are built for. init1 gates on this exact value
# (host `uname -r` must match) before touching the host — a mismatch is a crash,
# never a silent no-op.
ENV AMDGPU_KERNEL=6.12.74+deb13+1-amd64

# Host-mutation toolchain used by init1 (via nsenter the host's own binaries are
# used, but these make the container self-sufficient for extraction/hashing).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      xz-utils tar kmod ca-certificates bash coreutils \
 && rm -rf /var/lib/apt/lists/*

COPY patch/dkms_patch.tar.gz /opt/amdgpu-patch/dkms_patch.tar.gz
COPY scripts/ /opt/amdgpu-patch/scripts/

# Build-time verification oracle: extract the baked tarball to a throwaway dir and
# record the sha256 of every .ko.xz with paths RELATIVE to / (e.g.
# "lib/modules/<krel>/updates/dkms/amdgpu.ko.xz"). init1 streams this to the host
# and runs `cd / && sha256sum -c -`, so relative paths resolve against host /.
RUN set -eux; \
    tmp="$(mktemp -d)"; \
    tar -xzf /opt/amdgpu-patch/dkms_patch.tar.gz -C "$tmp"; \
    ( cd "$tmp" && find lib/modules -name '*.ko.xz' -type f | sort \
        | xargs sha256sum ) > /opt/amdgpu-patch/manifest.sha256; \
    echo "=== manifest.sha256 (verification oracle) ==="; \
    cat /opt/amdgpu-patch/manifest.sha256; \
    echo "=== module count ==="; \
    wc -l < /opt/amdgpu-patch/manifest.sha256; \
    echo "=== sizes (bytes) ==="; \
    ( cd "$tmp" && find lib/modules -name '*.ko.xz' -type f | sort \
        | xargs ls -l ); \
    rm -rf "$tmp"
