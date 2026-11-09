"""Shared helpers for the DR controller Lambdas."""
import json
import os
import time
from datetime import datetime, timezone
from decimal import Decimal

import boto3

_ssm = boto3.client("ssm")
_sns = boto3.client("sns")
_ddb = boto3.resource("dynamodb")

KEY = {"application": "crp"}
_cfg_cache = {"at": 0.0, "data": {}}


class ValidationFailed(Exception):
    """Raised when a post-recovery check fails (Step Functions retries it)."""


class LockHeld(Exception):
    """Another failover already owns the DR lock."""


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def num(x, default=0):
    if x is None:
        return default
    return float(x) if isinstance(x, Decimal) else x


def config(max_age: int = 30) -> dict:
    """All SSM parameters under /crp/ as {'aws/alb_dns': '...', 'dns/fqdn': '...'}."""
    if time.time() - _cfg_cache["at"] < max_age and _cfg_cache["data"]:
        return _cfg_cache["data"]
    out, token = {}, None
    while True:
        kw = {"Path": "/crp/", "Recursive": True, "WithDecryption": True}
        if token:
            kw["NextToken"] = token
        r = _ssm.get_parameters_by_path(**kw)
        for p in r["Parameters"]:
            out[p["Name"][len("/crp/"):]] = p["Value"]
        token = r.get("NextToken")
        if not token:
            break
    _cfg_cache.update(at=time.time(), data=out)
    return out


def table():
    return _ddb.Table(os.environ["TABLE"])


def get_state() -> dict:
    return table().get_item(Key=KEY, ConsistentRead=True).get("Item", {})


def notify(subject: str, message: str) -> None:
    topic = os.environ.get("SNS_TOPIC")
    if not topic:
        return
    try:
        _sns.publish(TopicArn=topic, Subject=subject[:99], Message=message[:200000])
    except Exception as exc:  # notification must never break the workflow
        print("notify failed:", exc)


def log(**kw):
    print(json.dumps(kw, default=str))
