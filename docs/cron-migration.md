# Cron Migration Notes

Existing bastion jobs found in the previous OpenClaw cron state:

| Name | Schedule | Keep? | New execution shape |
| --- | --- | --- | --- |
| Daily OCI cost report (MTD) | `30 7 * * *` Asia/Seoul | yes | `bastion-run python3 /home/opc/clawd/scripts/oci_mtd_cost_report.py` |
| daily dnf+brew update report | `50 8 * * *` Asia/Seoul | yes | `bastion-run /home/opc/clawd/scripts/daily_update_run_and_report.sh` |
| weekly disk cleanup | `30 9 * * 0` Asia/Seoul | yes | `bastion-run sudo -n /home/opc/cronjob/disk-cleanup.sh` |
| weekly Helm Chart update | `0 10 * * 5` Asia/Seoul | yes | `bash /host/app/openclaw-docker/cronjobs/helm-update.sh` from the Docker gateway, or `bastion-run bash /app/openclaw-docker/cronjobs/helm-update.sh` when explicitly running on the host |
| OpenClaw bastion gateway image update | `30 8 * * *` Asia/Seoul | yes | `bastion-run /app/openclaw-docker/scripts/update-openclaw-gateway-image` |
| openclaw-self-update | `0 1 * * *` Asia/Seoul | no | skip; the Docker image update job replaces it |
| openclaw-update-report | `0 10 * * *` Asia/Seoul | no | skip unless a report-only job is still wanted |

Because the gateway now runs on bastion, cron prompts no longer need to select a
paired node. Use `bastion-run ...` directly when a job needs host tools.
