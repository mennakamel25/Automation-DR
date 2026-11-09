"""Runs every minute in the DR region. Decides whether the *whole* primary region is down.

One instance, one AZ, or even a short database failover must NOT trigger a cross-region failover:
the primary region handles those itself (second web/api node, Patroni). We only count a failure when
  (a) the primary ALB fails the deep health check (web -> api -> database) from here, AND
  (b) Route 53's health checkers (many vantage points) agree it is unhealthy.
After `FAIL_THRESHOLD` consecutive failing minutes the failover state machine is started.
"""
import json
import math
import os
import socket
import ssl
import time
import urllib.request

import boto3
from botocore.exceptions import ClientError

import common

r53 = boto3.client("route53")
sfn = boto3.client("stepfunctions")


def deep_probe(host: str, fqdn: str) -> bool:
    """HTTPS GET /healthz/deep against the primary ALB (by its AWS DNS name) with SNI = the app FQDN."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE  # we test availability, not identity
    try:
        with socket.create_connection((host, 443), timeout=5) as sock:
            with ctx.wrap_socket(sock, server_hostname=fqdn) as s:
                s.settimeout(8)
                s.sendall(f"GET /healthz/deep HTTP/1.1\r\nHost: {fqdn}\r\nConnection: close\r\n\r\n".encode())
                head = s.recv(64)
        return head.startswith(b"HTTP/1.1 200") or head.startswith(b"HTTP/1.0 200")
    except Exception as exc:
        common.log(probe="deep", ok=False, error=str(exc)[:120])
        return False


def route53_votes(check_id: str):
    """(unhealthy, total) Route 53 checker observations for the primary-region endpoint."""
    if not check_id:
        return 0, 0
    try:
        obs = r53.get_health_check_status(HealthCheckId=check_id)["HealthCheckObservations"]
    except ClientError as exc:
        common.log(probe="route53", error=str(exc)[:120])
        return 0, 0
    bad = sum(1 for o in obs if o["StatusReport"]["Status"].startswith("Failure"))
    return bad, len(obs)


def patroni_primary(urls: dict):
    """Remember which DB node was the Patroni leader (reachable over the VPC peering). Used to pick the DRS database to recover."""
    for name, url in urls.items():
        try:
            with urllib.request.urlopen(url, timeout=2) as r:
                if r.status == 200:
                    return name
        except Exception:
            continue
    return None


def handler(event, context):
    cfg = common.config()
    host, fqdn = cfg.get("primary/alb_dns"), cfg.get("dns/fqdn")
    if not host or not fqdn:
        common.log(msg="controller config incomplete (terraform apply not finished?)")
        return {"status": "unconfigured"}

    deep_ok = deep_probe(host, fqdn)
    bad, total = route53_votes(cfg.get("dns/primary_health_check_id", ""))
    r53_agrees = total == 0 or bad >= max(1, math.ceil(total / 2))
    site_down = (not deep_ok) and r53_agrees

    urls = json.loads(cfg.get("primary/patroni_urls", "{}"))
    primary = patroni_primary(urls) if deep_ok or urls else None

    t = common.table()
    state = common.get_state()
    now = int(time.time())

    if site_down:
        t.update_item(
            Key=common.KEY,
            UpdateExpression="ADD consecutive_failures :one SET last_probe_at = :n, first_failure_epoch = if_not_exists(first_failure_epoch, :e)",
            ExpressionAttributeValues={":one": 1, ":n": common.now_iso(), ":e": now},
        )
    else:
        expr = "SET consecutive_failures = :z, last_probe_at = :n"
        vals = {":z": 0, ":n": common.now_iso()}
        if primary:
            expr += ", last_primary = :p"
            vals[":p"] = primary
        if state.get("dr_status") in ("NORMAL", None):
            expr += " REMOVE first_failure_epoch"
        t.update_item(Key=common.KEY, UpdateExpression=expr, ExpressionAttributeValues=vals)

    state = common.get_state()
    fails = int(common.num(state.get("consecutive_failures")))
    common.log(deep_ok=deep_ok, r53_bad=bad, r53_total=total, fails=fails, status=state.get("dr_status"), primary=primary)

    threshold = int(os.environ.get("FAIL_THRESHOLD", "5"))
    if site_down and fails >= threshold and state.get("dr_status") == "NORMAL" and state.get("active_site", "primary") == "primary":
        try:  # claim the detection atomically so only one probe starts the workflow
            t.update_item(
                Key=common.KEY,
                UpdateExpression="SET dr_status = :d",
                ConditionExpression="dr_status = :n",
                ExpressionAttributeValues={":d": "DETECTED", ":n": "NORMAL"},
            )
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return {"status": "already_detected"}
            raise
        ex = sfn.start_execution(
            stateMachineArn=os.environ["FAILOVER_SM"],
            name=f"failover-{int(time.time())}",
            input=json.dumps({"drill": False, "trigger": "auto"}),
        )
        common.notify(
            "[CRP] PRIMARY REGION FAILURE CONFIRMED - failover started",
            f"{fails} consecutive failed probes (deep check + {bad}/{total} Route 53 checkers).\nExecution: {ex['executionArn']}",
        )
        return {"status": "failover_started", "execution": ex["executionArn"]}
    return {"status": "healthy" if not site_down else "failing", "fails": fails}
