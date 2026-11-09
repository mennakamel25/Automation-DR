"""Step Functions task handler for the failover / failback / drill workflows.

Event shape:  {"action": "<name>", "ctx": <whole workflow state>, "execution": "<name>", ...extras}
Every action returns a small JSON-serialisable dict that Step Functions stores in the workflow state.
"""
import http.client
import json
import os
import ssl
import time

import boto3
from botocore.exceptions import ClientError

import common
import fence
from common import LockHeld, ValidationFailed

drs = boto3.client("drs")
ssm = boto3.client("ssm")
elb = boto3.client("elbv2")
r53 = boto3.client("route53")

PREFIX = os.environ.get("NAME_PREFIX", "crp")
TG_PORT = 443


# ---------------------------------------------------------------- helpers
def _servers_by_host():
    """hostname (short) -> DRS sourceServerID"""
    out, token = {}, None
    while True:
        kw = {"maxResults": 100}
        if token:
            kw["nextToken"] = token
        r = drs.describe_source_servers(filters={}, **kw)
        for s in r.get("items", []):
            host = s.get("sourceProperties", {}).get("identificationHints", {}).get("hostname", "")
            out[host.split(".")[0]] = s["sourceServerID"]
        token = r.get("nextToken")
        if not token:
            break
    return out


def _wave_hosts(wave: str, state: dict):
    if wave == "db":
        primary = state.get("last_primary") or "pg-a"  # which DB node was primary at the last good probe
        return [f"{PREFIX}-{primary}"]
    if wave == "api":
        return [f"{PREFIX}-api-a", f"{PREFIX}-api-b"]
    if wave == "web":
        return [f"{PREFIX}-web-a", f"{PREFIX}-web-b"]
    raise ValueError(wave)


def _run_ssm(instance_ids, commands, wait=75):
    if not instance_ids:
        raise ValidationFailed("no instances to validate")
    try:
        cid = ssm.send_command(
            InstanceIds=instance_ids,
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": commands},
            TimeoutSeconds=60,
        )["Command"]["CommandId"]
    except ClientError as exc:  # instance not yet registered with SSM
        raise ValidationFailed(f"ssm not ready: {exc.response['Error']['Code']}")
    deadline = time.time() + wait
    results = {}
    while time.time() < deadline and len(results) < len(instance_ids):
        for iid in instance_ids:
            if iid in results:
                continue
            try:
                inv = ssm.get_command_invocation(CommandId=cid, InstanceId=iid)
            except ClientError:
                continue
            if inv["Status"] in ("Success", "Failed", "Cancelled", "TimedOut"):
                results[iid] = inv
        time.sleep(3)
    for iid in instance_ids:
        inv = results.get(iid)
        if not inv or inv["Status"] != "Success":
            out = (inv or {}).get("StandardErrorContent", "") or (inv or {}).get("StandardOutputContent", "")
            raise ValidationFailed(f"{iid}: {(inv or {}).get('Status', 'no result')} {out[:200]}")
    return {iid: r["StandardOutputContent"].strip() for iid, r in results.items()}


# ---------------------------------------------------------------- actions
def request_approval(ev):
    ctx, token = ev["ctx"], ev["token"]
    kind = ev.get("kind", "failover")
    state = common.get_state()
    msg = (
        f"A {kind} is waiting for approval.\n\n"
        f"Primary-region probes failing: {int(common.num(state.get('consecutive_failures')))} in a row\n"
        f"Trigger: {ctx.get('trigger')}\n\n"
        f"APPROVE:\n  aws stepfunctions send-task-success --task-token '{token}' --task-output '{{\"approved\":true}}'\n\n"
        f"REJECT:\n  aws stepfunctions send-task-failure --task-token '{token}' --error Rejected --cause 'operator rejected'\n"
    )
    common.notify(f"[CRP] APPROVAL NEEDED: {kind}", msg)
    return {}  # the workflow now waits for send-task-success


def acquire_lock(ev):
    ctx = ev["ctx"]
    st = common.get_state()
    if ctx.get("drill"):
        return {"generation": int(common.num(st.get("failover_generation"), 1)), "started_epoch": time.time(), "drill": True}
    gen = int(common.num(st.get("failover_generation"), 1)) + 1
    try:
        common.table().update_item(
            Key=common.KEY,
            UpdateExpression="SET dr_status=:l, failover_generation=:g, lock_owner=:o, failover_started=:s",
            ConditionExpression="dr_status IN (:n, :d, :f)",
            ExpressionAttributeValues={":l": "LOCKED", ":g": gen, ":o": ev["execution"], ":s": common.now_iso(),
                                       ":n": "NORMAL", ":d": "DETECTED", ":f": "FAILED"},
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise LockHeld("DR lock is held by another failover")
        raise
    # recovered instances read this at boot: API tier + database adopt the new generation
    ssm.put_parameter(Name="/crp/state/failover_generation", Value=str(gen), Type="String", Overwrite=True)
    first = common.num(st.get("first_failure_epoch"), None)
    return {"generation": gen, "started_epoch": first or time.time(), "drill": False}


def fence_primary(ev):
    res = fence.stop_all(common.config(0))
    common.log(fence=res)
    return res


def start_recovery(ev):
    wave, ctx = ev["wave"], ev["ctx"]
    state = common.get_state()
    by_host = _servers_by_host()
    hosts = _wave_hosts(wave, state)
    missing = [h for h in hosts if h not in by_host]
    if missing:
        raise RuntimeError(f"DRS source servers not found for {missing}; known: {sorted(by_host)}")
    job = drs.start_recovery(
        isDrill=bool(ctx.get("drill")),
        sourceServers=[{"sourceServerID": by_host[h]} for h in hosts],
        tags={"crp-wave": wave, "crp-execution": ev["execution"][:60]},
    )["job"]
    common.log(wave=wave, job=job["jobID"], hosts=hosts, drill=ctx.get("drill"))
    return {"job_id": job["jobID"], "hosts": hosts, "source_ids": [by_host[h] for h in hosts]}


def check_job(ev):
    job_id = ev["job_id"]
    jobs = drs.describe_jobs(filters={"jobIDs": [job_id]})["items"]
    if not jobs:
        return {"done": False, "failed": False, "status": "UNKNOWN", "instances": [], "recovery_ids": []}
    job = jobs[0]
    status = job["status"]
    parts = job.get("participatingServers", [])
    launch = [p.get("launchStatus") for p in parts]
    failed = any(s == "FAILED" for s in launch)
    done = status == "COMPLETED" and all(s == "LAUNCHED" for s in launch)
    instances, rec_ids = [], []
    if status == "COMPLETED":
        rec_ids = [p["recoveryInstanceID"] for p in parts if p.get("recoveryInstanceID")]
        if rec_ids:
            for ri in drs.describe_recovery_instances(filters={"recoveryInstanceIDs": rec_ids})["items"]:
                if ri.get("ec2InstanceID"):
                    instances.append(ri["ec2InstanceID"])
        done = done and len(instances) == len(parts)
    return {"done": done, "failed": failed, "status": status, "launch": launch, "instances": instances, "recovery_ids": rec_ids}


def validate(ev):
    wave, instances = ev["wave"], ev["instances"]
    expected_gen = ssm.get_parameter(Name="/crp/state/failover_generation")["Parameter"]["Value"]
    if wave == "db":
        out = _run_ssm(instances, [
            "sudo -u postgres psql -d crp -Atqc \"SELECT (NOT pg_is_in_recovery())::text || ':' || (SELECT value FROM dr_meta WHERE key='failover_generation')\"",
        ])
        for iid, text in out.items():
            if text != f"true:{expected_gen}":
                raise ValidationFailed(f"{iid}: database not ready (got '{text}', want 'true:{expected_gen}')")
    elif wave == "api":
        _run_ssm(instances, ["curl -fsS -m 5 http://127.0.0.1:8000/readyz"])
    elif wave == "web":
        _run_ssm(instances, ["curl -fsSk -m 8 https://127.0.0.1/healthz/deep"])
    return {"ok": True, "wave": wave, "instances": instances}


def register_targets(ev):
    cfg = common.config(0)
    tg = cfg["dr/target_group_arn"]
    elb.register_targets(TargetGroupArn=tg, Targets=[{"Id": i, "Port": TG_PORT} for i in ev["instances"]])
    return {"registered": ev["instances"]}


def _https_json(host, path, method="GET", body=None, headers=None, timeout=10):
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE  # ALB DNS name != certificate name; we pin the Host header instead
    conn = http.client.HTTPSConnection(host, 443, timeout=timeout, context=ctx)
    conn.request(method, path, body=json.dumps(body) if body else None, headers=headers or {})
    r = conn.getresponse()
    data = r.read()
    return r.status, (json.loads(data) if data and r.getheader("content-type", "").startswith("application/json") else data)


def validate_e2e(ev):
    """Synthetic transaction through the DR-region ALB: info -> write -> read back."""
    cfg = common.config(0)
    alb, fqdn = cfg["dr/alb_dns"], cfg["dns/fqdn"]
    h = {"Host": fqdn, "Content-Type": "application/json"}
    st, info = _https_json(alb, "/api/info", headers=h)
    if st != 200 or not isinstance(info, dict) or info.get("site") != "dr" or not info.get("db_ok") or not info.get("writes_allowed"):
        raise ValidationFailed(f"info check failed: {st} {str(info)[:200]}")
    title = f"dr-validation-{int(time.time())}"
    st, created = _https_json(alb, "/api/items", "POST", {"title": title}, h)
    if st != 201:
        raise ValidationFailed(f"write failed: {st} {str(created)[:200]}")
    st, items = _https_json(alb, "/api/items", headers=h)
    if st != 200 or not any(i.get("title") == title for i in items):
        raise ValidationFailed("written item not found on read-back")
    return {"ok": True, "generation": info.get("db_generation")}


def _alias(cfg, fqdn, ident, weight, prefix):
    return {"Action": "UPSERT", "ResourceRecordSet": {
        "Name": fqdn, "Type": "A", "SetIdentifier": ident, "Weight": weight,
        "AliasTarget": {"HostedZoneId": cfg[f"{prefix}/alb_zone_id"], "DNSName": cfg[f"{prefix}/alb_dns"], "EvaluateTargetHealth": False}}}


def switch_dns(ev):
    target = ev["target"]  # "dr" | "primary"
    cfg = common.config(0)
    zone, fqdn = cfg["dns/zone_id"], cfg["dns/fqdn"]
    w_primary, w_dr = (100, 0) if target == "primary" else (0, 100)
    changes = [_alias(cfg, fqdn, "primary", w_primary, "primary"), _alias(cfg, fqdn, "dr", w_dr, "dr")]
    r = r53.change_resource_record_sets(HostedZoneId=zone, ChangeBatch={"Comment": f"CRP switch to {target}", "Changes": changes})
    return {"target": target, "change_id": r["ChangeInfo"]["Id"], "at": common.now_iso()}


def terminate_drill(ev):
    ctx = ev["ctx"]
    ids = []
    for wave in ("db", "api", "web"):
        ids += (ctx.get(f"chk_{wave}") or {}).get("recovery_ids", [])
    if ids:
        drs.terminate_recovery_instances(recoveryInstanceIDs=ids)
    return {"terminated": ids}


def finalize(ev):
    ctx = ev["ctx"]
    started = common.num((ctx.get("lock") or {}).get("started_epoch"), time.time())
    elapsed = int(time.time() - started)
    t = common.table()
    if ctx.get("drill"):
        t.update_item(
            Key=common.KEY,
            UpdateExpression="SET drill_last = :d",
            ExpressionAttributeValues={":d": {"at": common.now_iso(), "seconds": elapsed, "result": "PASSED", "execution": ev["execution"]}},
        )
        common.notify("[CRP] DR drill PASSED", f"Drill finished in {elapsed}s (instances terminated).")
        return {"drill": True, "seconds": elapsed}
    t.update_item(
        Key=common.KEY,
        UpdateExpression="SET active_site=:a, dr_status=:r, failover_completed=:c, rto_seconds=:rto, consecutive_failures=:z REMOVE first_failure_epoch",
        ExpressionAttributeValues={":a": "dr", ":r": "RECOVERED", ":c": common.now_iso(), ":rto": elapsed, ":z": 0},
    )
    common.notify("[CRP] FAILOVER COMPLETE - the DR region is active", f"Measured RTO: {elapsed}s ({elapsed // 60}m {elapsed % 60}s).\nGeneration: {(ctx.get('lock') or {}).get('generation')}")
    return {"active": "dr", "rto_seconds": elapsed}


def abort(ev):
    ctx = ev["ctx"]
    err = ctx.get("error") or {}
    common.table().update_item(
        Key=common.KEY,
        UpdateExpression="SET dr_status=:f, last_error=:e",
        ExpressionAttributeValues={":f": "FAILED", ":e": json.dumps(err, default=str)[:900]},
    )
    common.notify("[CRP] FAILOVER FAILED - DR origin NOT enabled", f"DNS was not switched. Lock stays FAILED for the operator.\n{json.dumps(err, default=str)[:3000]}")
    return {"aborted": True}


# ---------------------------------------------------------------- failback
def failback_precheck(ev):
    st = common.get_state()
    if st.get("active_site") != "dr" or st.get("dr_status") != "RECOVERED":
        raise RuntimeError(f"failback needs active_site=dr and dr_status=RECOVERED (got {st.get('active_site')}/{st.get('dr_status')})")
    cfg = common.config(0)
    import probe
    ok = 0
    for attempt in range(3):
        if probe.deep_probe(cfg["primary/alb_dns"], cfg["dns/fqdn"]):
            ok += 1
        if attempt < 2:
            time.sleep(3)
    if ok < 3:
        raise RuntimeError("Primary-region deep health check is not stable yet (need 3/3). Re-protect and sync the data back first, then retry.")
    return {"primary_healthy": True}


def failback_finalize(ev):
    st = common.get_state()
    gen = int(common.num(st.get("failover_generation"), 1)) + 1
    ssm.put_parameter(Name="/crp/state/failover_generation", Value=str(gen), Type="String", Overwrite=True)
    common.table().update_item(
        Key=common.KEY,
        UpdateExpression="SET active_site=:a, dr_status=:n, failover_generation=:g, failback_completed=:c, consecutive_failures=:z REMOVE lock_owner, last_error",
        ExpressionAttributeValues={":a": "primary", ":n": "NORMAL", ":g": gen, ":c": common.now_iso(), ":z": 0},
    )
    common.notify("[CRP] FAILBACK COMPLETE - the primary region is active again", f"Failover generation is now {gen}. Terminate the DR recovery instances and re-initialise forward replication (see docs/runbooks.md).")
    return {"active": "primary", "generation": gen}


ACTIONS = {
    "request_approval": request_approval, "acquire_lock": acquire_lock, "fence_primary": fence_primary,
    "start_recovery": start_recovery, "check_job": check_job, "validate": validate,
    "register_targets": register_targets, "validate_e2e": validate_e2e, "switch_dns": switch_dns,
    "terminate_drill": terminate_drill, "finalize": finalize, "abort": abort,
    "failback_precheck": failback_precheck, "failback_finalize": failback_finalize,
}


def handler(event, context):
    action = event["action"]
    common.log(action=action, execution=event.get("execution"))
    return ACTIONS[action](event)
