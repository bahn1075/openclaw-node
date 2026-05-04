# Cron Migration Notes

Existing bastion jobs found in `~/.openclaw/cron/jobs.json`:

| Name | Schedule | Keep? | New execution shape |
| --- | --- | --- | --- |
| Daily OCI cost report (MTD) | `30 7 * * *` Asia/Seoul | yes | `bastion-run python3 /home/opc/clawd/scripts/oci_mtd_cost_report.py` |
| daily dnf+brew update report | `50 8 * * *` Asia/Seoul | yes | `bastion-run /home/opc/clawd/scripts/daily_update_run_and_report.sh` |
| weekly disk cleanup | `30 9 * * 0` Asia/Seoul | yes | `bastion-run sudo -n /home/opc/cronjob/disk-cleanup.sh` |
| weekly Helm Chart update | `0 10 * * 5` Asia/Seoul | yes | `bastion-run /home/opc/cronjob/helm-update.sh` |
| openclaw-self-update | `0 1 * * *` Asia/Seoul | no | skip for Kubernetes-managed OpenClaw |
| openclaw-update-report | `0 10 * * *` Asia/Seoul | no | skip for Kubernetes-managed OpenClaw |

Discord delivery was configured on the old bastion gateway. If Discord is not
available on the Kubernetes gateway, create these jobs without delivery first,
or re-pair Discord from the Kubernetes OpenClaw dashboard.

