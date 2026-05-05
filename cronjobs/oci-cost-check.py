#!/usr/bin/env python3
"""Daily OCI month-to-date cost report for the OpenClaw gateway.

The old version expected to run on an OpenClaw node with local OCI config and
host tools. The gateway runs inside Docker on bastion, so all host-side access
goes through `bastion-run` when this script is launched inside the gateway
container. If the script is already invoked on bastion through `bastion-run`, it
can use the host commands directly.
"""

from __future__ import annotations

import argparse
import configparser
import json
import os
import shutil
import subprocess
import sys
from collections import defaultdict
from collections.abc import Sequence
from datetime import date, datetime, timedelta, timezone

import fcntl


KST = timezone(timedelta(hours=9))
DEFAULT_BASTION_RUN = "bastion-run"
DEFAULT_CONFIG_FILE = "/home/opc/.oci/config"
DEFAULT_LOCK_PATH = "/tmp/oci_mtd_cost_report.lock"
DEFAULT_CHUNK_HOURS = 36
DEFAULT_CURL_TIMEOUT_SECONDS = 8
DEFAULT_WARNING_INCREASE_PERCENT = 30.0


class CommandRunner:
    def __init__(self, mode: str, prefix: Sequence[str]) -> None:
        self.mode = mode
        self.prefix = list(prefix)

    def stdout(self, args: Sequence[str], *, timeout: int | None = None) -> str:
        command = [*self.prefix, *args]
        return subprocess.check_output(
            command,
            stderr=None,
            timeout=timeout,
        ).decode("utf-8", "ignore")


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def non_negative_float(value: str) -> float:
    parsed = float(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be zero or greater")
    return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Report OCI month-to-date cost from the OpenClaw gateway."
    )
    parser.add_argument(
        "--bastion-run",
        default=os.environ.get("OPENCLAW_BASTION_RUN", DEFAULT_BASTION_RUN),
        help="bastion-run executable inside the gateway container",
    )
    parser.add_argument(
        "--execution",
        choices=("auto", "gateway", "host"),
        default=os.environ.get("OCI_COST_CHECK_EXECUTION", "auto"),
        help=(
            "gateway uses bastion-run, host runs commands directly, and auto "
            "prefers gateway when bastion-run is available"
        ),
    )
    parser.add_argument(
        "--config-file",
        default=os.environ.get("OCI_CONFIG_FILE", DEFAULT_CONFIG_FILE),
        help="OCI config path on the bastion host",
    )
    parser.add_argument(
        "--profile",
        default=os.environ.get("OCI_CLI_PROFILE", "DEFAULT"),
        help="OCI CLI profile to use",
    )
    parser.add_argument(
        "--lock-path",
        default=os.environ.get("OCI_COST_CHECK_LOCK", DEFAULT_LOCK_PATH),
        help="local lock path inside the gateway container",
    )
    parser.add_argument(
        "--chunk-hours",
        type=positive_int,
        default=positive_int(
            os.environ.get("OCI_COST_CHECK_CHUNK_HOURS", str(DEFAULT_CHUNK_HOURS))
        ),
        help="hours per OCI usage query chunk",
    )
    parser.add_argument(
        "--warning-threshold-percent",
        type=non_negative_float,
        default=non_negative_float(
            os.environ.get(
                "OCI_COST_WARNING_THRESHOLD_PERCENT",
                str(DEFAULT_WARNING_INCREASE_PERCENT),
            )
        ),
        help="warn when yesterday is this percent above the prior daily average",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print the gateway/host execution settings without querying OCI",
    )
    return parser


def resolve_runner(execution: str, bastion_run_path: str) -> CommandRunner:
    resolved = shutil.which(bastion_run_path)
    if execution == "gateway":
        if resolved is None:
            raise RuntimeError(
                "bastion-run was not found in PATH. Run this script inside the "
                "openclaw-gateway-bastion container, or set OPENCLAW_BASTION_RUN."
            )
        return CommandRunner("gateway", [resolved])

    if execution == "host":
        return CommandRunner("host", [])

    if resolved is not None:
        return CommandRunner("gateway", [resolved])

    return CommandRunner("host", [])


def read_host_oci_config(
    runner: CommandRunner,
    config_file: str,
) -> configparser.RawConfigParser:
    raw_config = runner.stdout(["cat", config_file])
    parser = configparser.RawConfigParser()
    parser.read_string(raw_config)
    return parser


def get_tenancy(
    runner: CommandRunner,
    config_file: str,
    profile: str,
) -> str:
    parser = read_host_oci_config(runner, config_file)
    if profile not in parser:
        raise RuntimeError(f"OCI profile not found in {config_file}: {profile}")

    tenancy = parser[profile].get("tenancy")
    if not tenancy:
        raise RuntimeError(f"tenancy not found in {config_file} profile {profile}")
    return tenancy


def iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_oci_datetime(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def date_range(start: date, end: date) -> list[date]:
    if end < start:
        return []

    days = []
    current = start
    while current <= end:
        days.append(current)
        current += timedelta(days=1)
    return days


def format_cost(sgd: float, rate: float) -> str:
    return f"**{sgd:.2f} SGD / ₩{sgd * rate:,.2f}**"


def get_ecb_rate_sgd_krw(runner: CommandRunner) -> tuple[float, str]:
    try:
        raw = runner.stdout(
            [
                "curl",
                "-sS",
                "--max-time",
                str(DEFAULT_CURL_TIMEOUT_SECONDS),
                "https://api.frankfurter.app/latest?from=SGD&to=KRW",
            ],
            timeout=DEFAULT_CURL_TIMEOUT_SECONDS + 4,
        ).strip()
        if raw:
            data = json.loads(raw)
            return float(data["rates"]["KRW"]), data["date"]
    except Exception:
        pass

    raw = runner.stdout(
        [
            "curl",
            "-sS",
            "--max-time",
            str(DEFAULT_CURL_TIMEOUT_SECONDS),
            "https://open.er-api.com/v6/latest/SGD",
        ],
        timeout=DEFAULT_CURL_TIMEOUT_SECONDS + 4,
    )
    data = json.loads(raw)
    rate = float(data["rates"]["KRW"])
    ref_date = data.get("time_last_update_utc", "unknown")[:16]
    return rate, ref_date


def fetch_oci_cost_items_hourly(
    runner: CommandRunner,
    config_file: str,
    profile: str,
    tenant_id: str,
    start_utc: datetime,
    end_utc: datetime,
    chunk_hours: int,
) -> list[dict[str, object]]:
    items: list[dict[str, object]] = []
    started_at = start_utc

    while started_at < end_utc:
        ended_at = min(started_at + timedelta(hours=chunk_hours), end_utc)
        output = runner.stdout(
            [
                "oci",
                "--config-file",
                config_file,
                "--profile",
                profile,
                "usage-api",
                "usage-summary",
                "request-summarized-usages",
                "--tenant-id",
                tenant_id,
                "--time-usage-started",
                iso(started_at),
                "--time-usage-ended",
                iso(ended_at),
                "--granularity",
                "HOURLY",
                "--query-type",
                "COST",
                "--output",
                "json",
            ],
        )
        chunk = json.loads(output).get("data", {}).get("items", [])
        items.extend(chunk)
        started_at = ended_at

    return items


def print_report(
    runner: CommandRunner,
    config_file: str,
    profile: str,
    chunk_hours: int,
    warning_threshold_percent: float,
) -> None:
    rate, ref_date = get_ecb_rate_sgd_krw(runner)
    tenant_id = get_tenancy(runner, config_file, profile)

    now_kst = datetime.now(KST)
    report_date = now_kst.date()
    month_start = report_date.replace(day=1)
    yesterday = report_date - timedelta(days=1)
    two_days_ago = report_date - timedelta(days=2)

    # OCI cost usage is billed on UTC usage days. Starting from KST month start
    # includes the prior UTC month for the first nine hours of the KST month.
    start_utc = datetime(
        month_start.year,
        month_start.month,
        month_start.day,
        tzinfo=timezone.utc,
    )
    end_utc = datetime.now(timezone.utc).replace(
        minute=0,
        second=0,
        microsecond=0,
    )
    if end_utc <= start_utc:
        end_utc = start_utc + timedelta(hours=1)

    items = fetch_oci_cost_items_hourly(
        runner,
        config_file,
        profile,
        tenant_id,
        start_utc,
        end_utc,
        chunk_hours,
    )

    sum_by_day: defaultdict[date, float] = defaultdict(float)
    for item in items:
        amount = item.get("computed-amount")
        usage_started = item.get("time-usage-started")
        if amount is None or not isinstance(usage_started, str):
            continue

        usage_day = parse_oci_datetime(usage_started).astimezone(timezone.utc).date()
        if month_start <= usage_day <= yesterday:
            sum_by_day[usage_day] += float(amount)

    mtd_days = date_range(month_start, yesterday)
    average_days = date_range(month_start, two_days_ago)

    mtd_sgd = sum(sum_by_day.get(day, 0.0) for day in mtd_days)
    two_days_ago_sgd = sum_by_day.get(two_days_ago, 0.0)
    average_sgd = (
        sum(sum_by_day.get(day, 0.0) for day in average_days) / len(average_days)
        if average_days
        else 0.0
    )
    yesterday_sgd = sum_by_day.get(yesterday, 0.0)

    print(f"📊 OCI Daily Cost Report ({now_kst:%Y-%m-%d} KST)")
    print(f"FX: 1 SGD = {rate:,.2f} KRW (ECB ref {ref_date})")
    print(f"- 당월 합산 ({month_start:%-m/%-d}~어제): {format_cost(mtd_sgd, rate)}")
    print(f"- 2일전 요금 ({two_days_ago:%Y-%m-%d}): {format_cost(two_days_ago_sgd, rate)}")
    print(
        "- 당월 1일부터 2일전까지의 요금의 평균 발생량 "
        f"({month_start:%Y-%m-%d}~{two_days_ago:%Y-%m-%d}): "
        f"{format_cost(average_sgd, rate)}"
    )
    print(f"- 어제 요금 ({yesterday:%Y-%m-%d}): {format_cost(yesterday_sgd, rate)}")

    warning_multiplier = 1 + (warning_threshold_percent / 100)
    if average_sgd > 0 and yesterday_sgd >= average_sgd * warning_multiplier:
        increase_percent = ((yesterday_sgd / average_sgd) - 1) * 100
        print(
            "⚠️ 경고: 어제 요금이 당월 1일부터 2일전까지의 평균 대비 "
            f"{increase_percent:.1f}% 증가했습니다."
        )


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    try:
        runner = resolve_runner(args.execution, args.bastion_run)
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 127

    if args.dry_run:
        print("OCI cost check gateway settings:")
        print(f"- execution: {runner.mode}")
        if runner.prefix:
            print(f"- command prefix: {' '.join(runner.prefix)}")
        print(f"- host OCI config: {args.config_file}")
        print(f"- OCI profile: {args.profile}")
        print(f"- chunk hours: {args.chunk_hours}")
        print("- aggregation: OCI UTC billing days")
        print(f"- warning threshold: {args.warning_threshold_percent:g}%")
        return 0

    with open(args.lock_path, "w", encoding="utf-8") as lock_file:
        try:
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("SKIP: another OCI Daily Cost Report run is already in progress.")
            return 0

        try:
            print_report(
                runner,
                args.config_file,
                args.profile,
                args.chunk_hours,
                args.warning_threshold_percent,
            )
        except subprocess.CalledProcessError as exc:
            print(f"ERROR: host command failed with exit code {exc.returncode}", file=sys.stderr)
            return exc.returncode
        except Exception as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
