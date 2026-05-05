# OpenClaw Bastion Gateway

Docker-based OpenClaw gateway for the `bastion` host.

The container runs `openclaw gateway run` directly on bastion and reuses the
existing `openclaw-node-state` Docker volume for persistent OpenClaw state.

Host tools are intentionally executed through wrappers:

- `bastion-run <command>` runs a command on the bastion host as `opc`.
- `oci`, `kubectl`, `helm`, `jq`, `yq`, `dnf`, `brew`, `systemctl`,
  `journalctl`, `docker`, `crictl`, and `tailscale` inside the container are
  wrappers that call the host command through `bastion-run`.
- `sudo` inside the container delegates to host `sudo` as `opc`.

This lets OpenClaw gateway cron jobs and agents use the host's OCI CLI,
kubeconfig, shell scripts, package managers, Docker, and Tailscale CLI while
keeping OpenClaw itself in Docker.

Browser control is intentionally not configured on bastion.

## Deploy

```bash
cp .env.example .env
$EDITOR .env
docker compose up -d --build
```

The ChatGPT/OpenAI auth profile is stored in the Docker volume. It was imported
once from the Kubernetes OpenClaw pod during migration; no cluster sync is
required after that.

## Verify

```bash
docker exec openclaw-gateway-bastion bastion-run whoami
docker exec openclaw-gateway-bastion oci --version
docker exec openclaw-gateway-bastion kubectl config current-context
docker exec openclaw-gateway-bastion openclaw gateway health --port 18789 --token "$OPENCLAW_GATEWAY_TOKEN"
```

## Update

The gateway image is pinned through `.env`:

```bash
OPENCLAW_BASE_IMAGE_TAG=2026.5.2
```

Update to the latest stable official `ghcr.io/openclaw/openclaw` tag and
restart the gateway:

```bash
/app/openclaw-docker/scripts/update-openclaw-gateway-image
```

The update script verifies the gateway health endpoint and the bastion host-tool
wrapper. Old custom/base image tags are removed after a successful restart.

## Cron Prompt Pattern

Gateway cron jobs can call bastion tools directly:

```text
Run:
bastion-run bash -lc '<existing bastion command or script>'
```
