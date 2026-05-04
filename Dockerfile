ARG OPENCLAW_BASE_IMAGE=ghcr.io/openclaw/openclaw
ARG OPENCLAW_BASE_IMAGE_TAG=2026.5.2

FROM ${OPENCLAW_BASE_IMAGE}:${OPENCLAW_BASE_IMAGE_TAG}

USER root

RUN mkdir -p /home/openclaw/.openclaw /usr/local/lib/openclaw-node

COPY scripts/bastion-run /usr/local/bin/bastion-run
COPY scripts/host-wrapper /usr/local/lib/openclaw-node/host-wrapper
COPY scripts/sudo-wrapper /usr/local/lib/openclaw-node/sudo-wrapper

RUN chmod 0755 /usr/local/bin/bastion-run \
    /usr/local/lib/openclaw-node/host-wrapper \
    /usr/local/lib/openclaw-node/sudo-wrapper \
    && for tool in oci kubectl helm jq yq dnf brew systemctl journalctl docker crictl; do \
      ln -sf /usr/local/lib/openclaw-node/host-wrapper "/usr/local/bin/${tool}"; \
    done \
    && ln -sf /usr/local/lib/openclaw-node/sudo-wrapper /usr/local/bin/sudo

WORKDIR /home/openclaw
