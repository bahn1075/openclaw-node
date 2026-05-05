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

Discord is bootstrapped by the container startup wrapper. On each start it
refreshes the OpenClaw plugin registry, installs/enables the official
`@openclaw/discord` plugin if it is missing, and creates the Discord channel
account on first boot when `DISCORD_BOT_TOKEN` is set in `.env`.

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
docker exec openclaw-gateway-bastion node -e "fetch('http://127.0.0.1:18789/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
docker exec openclaw-gateway-bastion openclaw plugins list --json | jq -e '.plugins[] | select(.id == "discord")'
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
wrapper, then confirms the Discord plugin is available. Old custom/base image
tags are removed after a successful restart.

## Discord Channel

Discord channel policy is configured in the persisted OpenClaw config volume.
The bot token is supplied from `DISCORD_BOT_TOKEN` in `.env` and referenced from
OpenClaw config as an env-backed secret.

Current access model:

- Discord channel enabled: `channels.discord.enabled=true`
- Bot application ID: `1465917469800661193`
- Allowed server/guild ID: `1465918021892837459`
- Allowed human user ID: `474574636240076825`
- Guild policy: `allowlist`
- Guild replies do **not** require a bot mention:
  `channels.discord.guilds["1465918021892837459"].requireMention=false`
- Because the server only contains the human user and the bot, normal user
  messages in allowed guild channels should be answered without DM or mention.
- Bot-authored messages are ignored: `channels.discord.allowBots=false`
- DM access is restricted to the allowed user:
  `channels.discord.dmPolicy="allowlist"` and
  `channels.discord.allowFrom=["474574636240076825"]`
- The bot token is intentionally not documented here. Rotate it immediately if
  it is ever exposed outside trusted private setup context.

The gateway startup wrapper installs/enables the Discord plugin automatically.
After changing Discord settings, restart the Gateway and verify with:

```bash
docker exec openclaw-gateway-bastion openclaw status --deep
```

The `Channels` table should show Discord as `ON` / `OK`, for example:

```text
Discord | ON | OK | token config (...) · accounts 1/1
```

If the bot does not answer guild messages, confirm the Discord Developer Portal
has Message Content Intent enabled and that the bot has View Channels, Send
Messages, and Read Message History permissions in the server/channel.

Supply-chain note: OpenClaw may warn that the Discord plugin reads env-backed
credentials and sends network requests. This is expected for the official
Discord channel plugin.

## Cron Prompt Pattern

Gateway cron jobs can call bastion tools directly:

```text
Run:
bastion-run bash -lc '<existing bastion command or script>'
```
