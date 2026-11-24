# Sysemble engine image (P1-e2a).
#
# Frozen contract: docs/plan/P1-e2-workplan.md sections 2.1 and 4. The image is
# the disposable Linux build sandbox: it runs the same builders/debian/build.sh
# and tools/boot-check.sh as the host/CI, so it must carry both the build
# toolchain (mmdebstrap, GPT/FAT/GRUB, xorriso) and the boot-verification
# toolchain (QEMU + OVMF).
#
# The base is pinned by digest. `debian:trixie-slim` is a multi-arch index; the
# digest below is the index digest reported by
#   docker buildx imagetools inspect debian:trixie-slim
# and resolves to the linux/amd64 manifest
#   sha256:ab3b3c8c5159eebfca4376430132d53c4d425f869c765ecbe47177a030da575d
# Bump both the tag and the digest together; engine/image/build-image.sh
# --verify fails if the manifest's base does not match this line.
FROM --platform=linux/amd64 debian:trixie-slim@sha256:8aa5a7bf5a1955bddbe7d74fcdd0b91ab30e74362a8b73af672b0481b35b44a0

# Reproducibility timestamp (default 2026-11-24T00:00:00Z). The build script
# passes it through; --verify does not compare it, but it is recorded in the
# manifest and exposed inside the image for tools that honor it.
ARG SOURCE_DATE_EPOCH=1795478400
ARG SYSEMBLE_ENGINE_VERSION=0.1.0
ARG SYSEMBLE_ENGINE_REVISION=local

LABEL org.opencontainers.image.title="sysemble-engine" \
      org.opencontainers.image.description="Sysemble Linux build and boot-verification engine (Debian trixie, linux/amd64)" \
      org.opencontainers.image.version="${SYSEMBLE_ENGINE_VERSION}" \
      org.opencontainers.image.revision="${SYSEMBLE_ENGINE_REVISION}" \
      org.opencontainers.image.source="https://github.com/yiaogit/Sysemble" \
      org.opencontainers.image.base.name="docker.io/library/debian:trixie-slim@sha256:8aa5a7bf5a1955bddbe7d74fcdd0b91ab30e74362a8b73af672b0481b35b44a0" \
      org.opencontainers.image.base.digest="sha256:8aa5a7bf5a1955bddbe7d74fcdd0b91ab30e74362a8b73af672b0481b35b44a0"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}

# One layer: no recommends, no apt lists, no cached debs. Package groups:
#   build:      mmdebstrap, debian-archive-keyring, e2fsprogs, gdisk, dosfstools,
#               mtools, grub-efi-amd64-bin, grub-common, xorriso, squashfs-tools
#   boot-check: qemu-system-x86, qemu-utils, ovmf
#   shell/JSON: rsync, jq, expect, curl, ca-certificates, file, procps, util-linux,
#               bash, coreutils, grep, sed, gawk, findutils, tar, gzip, xz-utils, zstd
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      coreutils \
      curl \
      debian-archive-keyring \
      dosfstools \
      e2fsprogs \
      expect \
      file \
      findutils \
      gawk \
      gdisk \
      grep \
      grub-common \
      grub-efi-amd64-bin \
      gzip \
      jq \
      mmdebstrap \
      mtools \
      ovmf \
      procps \
      qemu-system-x86 \
      qemu-utils \
      rsync \
      sed \
      squashfs-tools \
      tar \
      util-linux \
      xorriso \
      xz-utils \
      zstd \
 && rm -rf /var/lib/apt/lists/*

# Use bash as /bin/sh in the *engine* container (the guest rootfs that
# mmdebstrap builds keeps Debian's dash).
#
# Why: mmdebstrap feeds apt a dpkg pre-install hook of the form
# `cat >&<fd>` and the fd is inherited from the parent process. On Apple
# Silicon, Rosetta keeps descriptors 3..9 open in every process, so the hook
# fd is >= 10; dash rejects multi-digit redirections with "Syntax error: Bad
# fd number" and mmdebstrap aborts. bash in sh mode supports them. Native
# amd64 is unaffected either way, and no package is reinstalled at runtime.
RUN ln -sf bash /bin/sh

# The CI/desktop callers always invoke an explicit command
# (`bash builders/...`), so there is deliberately no ENTRYPOINT.
WORKDIR /work
CMD ["bash"]
