# OpenClaw Bastion Node

Docker-based OpenClaw node for the `bastion` host.

The container runs `openclaw node run` and connects to the Kubernetes OpenClaw
gateway at `openclaw.tail651fca.ts.net:443`.

Host tools are intentionally executed through wrappers:

- `bastion-run <command>` runs a command on the bastion host as `opc`.
- `oci`, `kubectl`, `helm`, `jq`, `yq`, `dnf`, `brew`, `systemctl`,
  `journalctl`, and `docker` inside the container are wrappers that call the
  host command through `bastion-run`.
- `sudo` inside the container delegates to host `sudo` as `opc`.

This lets OpenClaw node invocations use the host's OCI CLI, kubeconfig, shell
scripts, and package managers while keeping the node process in a single Docker
container.

## Deploy

```bash
cp .env.example .env
$EDITOR .env
docker compose up -d --build
```

After first start, approve the pending node pairing from the gateway:

```bash
openclaw nodes pending --url wss://openclaw.tail651fca.ts.net --token "$OPENCLAW_GATEWAY_TOKEN"
openclaw nodes approve <request-id> --url wss://openclaw.tail651fca.ts.net --token "$OPENCLAW_GATEWAY_TOKEN"
```

## Verify

```bash
docker exec openclaw-node-bastion bastion-run whoami
docker exec openclaw-node-bastion oci --version
docker exec openclaw-node-bastion kubectl config current-context
docker exec openclaw-node-bastion openclaw node status
```

## Update

The node image is pinned through `.env`:

```bash
OPENCLAW_BASE_IMAGE_TAG=2026.5.2
```

Update to the latest stable official `ghcr.io/openclaw/openclaw` tag and
restart the node:

```bash
/app/openclaw-node/scripts/update-openclaw-node-image
```

The compose file overrides the gateway image healthcheck with a node-mode
process healthcheck. The update script also confirms that the paired `bastion`
node is connected to the Kubernetes gateway. Old custom/base image tags are
removed after a successful restart.

## Cron Prompt Pattern

Prefer this pattern for gateway cron jobs that need bastion tools:

```text
Use the paired node named "bastion".
Invoke exec on that node and run:
bastion-run bash -lc '<existing bastion command or script>'
```

Avoid installing OCI CLI, kubectl, or host-specific credentials in the
Kubernetes OpenClaw pod.
