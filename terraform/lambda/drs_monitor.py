"""Every 5 minutes: publish DRS replication health as CloudWatch metrics (namespace CRP/DRS)."""
import re

import boto3

drs = boto3.client("drs")
cw = boto3.client("cloudwatch")

_DUR = re.compile(r"^P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$")


def seconds(iso):
    if not iso:
        return 0.0
    m = _DUR.match(iso)
    if not m:
        return 0.0
    d, h, mi, s = (float(x) if x else 0.0 for x in m.groups())
    return d * 86400 + h * 3600 + mi * 60 + s


def handler(event, context):
    servers, token = [], None
    while True:
        kw = {"maxResults": 100}
        if token:
            kw["nextToken"] = token
        r = drs.describe_source_servers(filters={}, **kw)
        servers += r.get("items", [])
        token = r.get("nextToken")
        if not token:
            break

    max_lag, unhealthy, detail = 0.0, 0, []
    for s in servers:
        info = s.get("dataReplicationInfo", {})
        state = info.get("dataReplicationState", "UNKNOWN")
        lag = seconds(info.get("lagDuration"))
        host = s.get("sourceProperties", {}).get("identificationHints", {}).get("hostname", s["sourceServerID"])
        max_lag = max(max_lag, lag)
        if state != "CONTINUOUS":
            unhealthy += 1
        detail.append({"host": host, "state": state, "lag": lag})

    cw.put_metric_data(
        Namespace="CRP/DRS",
        MetricData=[
            {"MetricName": "SourceServerCount", "Value": len(servers), "Unit": "Count"},
            {"MetricName": "UnhealthyServers", "Value": unhealthy, "Unit": "Count"},
            {"MetricName": "MaxLagSeconds", "Value": max_lag, "Unit": "Seconds"},
        ],
    )
    print(detail)
    return {"servers": len(servers), "unhealthy": unhealthy, "max_lag": max_lag}
