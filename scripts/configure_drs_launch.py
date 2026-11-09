#!/usr/bin/env python3
"""Pin every DRS source server to its DR-region AZ/subnet/security group/instance type.

DRS does not recreate your topology: each source server has an EC2 launch template that you must
configure. Run this after the six primary-region instances show up in
`aws drs describe-source-servers --region <dr-region>`.

  terraform -chdir=terraform output -json drs_launch_settings > /tmp/launch.json
  scripts/configure_drs_launch.py /tmp/launch.json       (or omit the argument to call terraform)
"""
import json
import subprocess
import sys
from pathlib import Path

import boto3


def load():
    if len(sys.argv) > 1:
        return json.loads(Path(sys.argv[1]).read_text())
    root = Path(__file__).resolve().parent.parent / "terraform"
    return json.loads(subprocess.check_output(["terraform", f"-chdir={root}", "output", "-json", "drs_launch_settings"]))


def main():
    cfg = load()
    region = cfg["region"]
    drs = boto3.client("drs", region_name=region)
    ec2 = boto3.client("ec2", region_name=region)

    by_host, token = {}, None
    while True:
        kw = {"maxResults": 100, **({"nextToken": token} if token else {})}
        r = drs.describe_source_servers(filters={}, **kw)
        for s in r["items"]:
            host = s.get("sourceProperties", {}).get("identificationHints", {}).get("hostname", "").split(".")[0]
            by_host[host] = s["sourceServerID"]
        token = r.get("nextToken")
        if not token:
            break

    missing = []
    for host, meta in cfg["servers"].items():
        sid = by_host.get(host)
        if not sid:
            missing.append(host)
            continue
        tier, az = meta["tier"], meta["az"]
        drs.update_launch_configuration(
            sourceServerID=sid,
            launchDisposition="STARTED",
            targetInstanceTypeRightSizingMethod="NONE",   # explicit sizes, never guess for the database
            copyPrivateIp=False,                          # new IPs; services find each other via private DNS
            copyTags=True,
        )
        tid = drs.get_launch_configuration(sourceServerID=sid)["ec2LaunchTemplateID"]
        ver = ec2.create_launch_template_version(
            LaunchTemplateId=tid,
            SourceVersion="$Latest",
            VersionDescription="crp: AZ/subnet/SG/profile/type",
            LaunchTemplateData={
                "InstanceType": cfg["instance_types"][tier],
                "IamInstanceProfile": {"Name": cfg["instance_profiles"][tier]},
                "MetadataOptions": {"HttpTokens": "required", "HttpEndpoint": "enabled"},
                "NetworkInterfaces": [{
                    "DeviceIndex": 0,
                    "SubnetId": cfg["subnets"][tier][az],
                    "Groups": [cfg["security_groups"][tier]],
                    "AssociatePublicIpAddress": False,
                }],
            },
        )["LaunchTemplateVersion"]["VersionNumber"]
        ec2.modify_launch_template(LaunchTemplateId=tid, DefaultVersion=str(ver))
        print(f"ok  {host:12s} -> {tier:3s} az{'ab'[az]}  {cfg['instance_types'][tier]}  template {tid} v{ver}")

    if missing:
        print("\nNot registered with DRS yet (agent still installing?):", ", ".join(missing))
        sys.exit(1)


if __name__ == "__main__":
    main()
