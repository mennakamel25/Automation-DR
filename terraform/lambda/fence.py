"""Best-effort fencing of the primary region: stop every CRP instance there.

If the whole region is really down the EC2 call fails quickly and the Route 53 weight switch is the fence.
If the region is only partly broken (for example just the ALB or the network), stopping the instances
guarantees the old primary cannot keep writing while the DR copy takes over. The failover generation in
the database is the second line of defence.
"""
import os

import boto3
from botocore.config import Config


def stop_all(cfg: dict) -> dict:
    region = cfg.get("primary/region", "")
    prefix = os.environ.get("NAME_PREFIX", "crp")
    if not region:
        return {"fenced": False, "detail": "primary region not configured"}
    ec2 = boto3.client(
        "ec2",
        region_name=region,
        config=Config(connect_timeout=5, read_timeout=10, retries={"max_attempts": 1}),
    )
    try:
        res = ec2.describe_instances(
            Filters=[
                {"Name": "tag:Project", "Values": [prefix]},
                {"Name": "tag:Site", "Values": ["primary"]},
                {"Name": "instance-state-name", "Values": ["pending", "running"]},
            ]
        )
        ids = [i["InstanceId"] for r in res["Reservations"] for i in r["Instances"]]
        if not ids:
            return {"fenced": True, "stopped": []}
        ec2.stop_instances(InstanceIds=ids, Force=True)
        return {"fenced": True, "stopped": ids}
    except Exception as exc:  # region unreachable is expected in a real disaster
        return {"fenced": False, "detail": str(exc)[:200]}
