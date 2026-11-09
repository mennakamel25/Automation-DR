# DR controller (runs in the DR region, so it keeps working when the primary region is down):
# probe Lambda (every minute) -> Step Functions failover workflow -> AWS DRS recovery in waves ->
# validation -> Route 53 weighted-record switch. State + lock live in DynamoDB.

locals {
  fn_prefix        = "${var.name_prefix}-dr"
  failover_sm_name = "${var.name_prefix}-failover"
  failback_sm_name = "${var.name_prefix}-failback"
  failover_sm_arn  = "arn:aws:states:${var.dr_region}:${local.account_id}:stateMachine:${local.failover_sm_name}"
}

# ---------------------------------------------------------------- state + notifications
resource "aws_dynamodb_table" "state" {
  provider     = aws.dr
  name         = "${var.name_prefix}-dr-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "application"

  attribute {
    name = "application"
    type = "S"
  }
  point_in_time_recovery {
    enabled = true
  }
  server_side_encryption {
    enabled = true
  }
}

resource "aws_dynamodb_table_item" "initial" {
  provider   = aws.dr
  table_name = aws_dynamodb_table.state.name
  hash_key   = aws_dynamodb_table.state.hash_key
  item = jsonencode({
    application          = { S = "crp" }
    active_site          = { S = "primary" }
    dr_status            = { S = "NORMAL" }
    failover_generation  = { N = "1" }
    consecutive_failures = { N = "0" }
  })
  lifecycle { ignore_changes = [item] }
}

resource "aws_sns_topic" "dr" {
  provider          = aws.dr
  name              = "${var.name_prefix}-dr-events"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  provider  = aws.dr
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.dr.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ---------------------------------------------------------------- Lambda package + IAM
data "archive_file" "controller" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/.build/controller.zip"
  excludes    = ["__pycache__"]
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "controller" {
  provider           = aws.dr
  name               = "${var.name_prefix}-controller"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "controller_basic" {
  provider   = aws.dr
  role       = aws_iam_role.controller.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "controller" {
  provider = aws.dr
  name     = "controller"
  role     = aws_iam_role.controller.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"], Resource = aws_dynamodb_table.state.arn },
      { Effect = "Allow", Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"], Resource = "arn:aws:ssm:${var.dr_region}:${local.account_id}:parameter/crp*" },
      { Effect = "Allow", Action = ["ssm:PutParameter"], Resource = "arn:aws:ssm:${var.dr_region}:${local.account_id}:parameter/crp/state/*" },
      { Effect = "Allow", Action = ["ssm:SendCommand", "ssm:GetCommandInvocation", "ssm:DescribeInstanceInformation"], Resource = "*" },
      { Effect = "Allow", Action = ["drs:DescribeSourceServers", "drs:DescribeJobs", "drs:DescribeRecoveryInstances", "drs:StartRecovery", "drs:TerminateRecoveryInstances", "drs:TagResource", "drs:DescribeJobLogItems"], Resource = "*" },
      { Effect = "Allow", Action = ["ec2:Describe*"], Resource = "*" },
      { Effect = "Allow", Action = ["elasticloadbalancing:RegisterTargets", "elasticloadbalancing:DeregisterTargets", "elasticloadbalancing:DescribeTargetHealth"], Resource = "*" },
      { Effect = "Allow", Action = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"], Resource = "arn:aws:route53:::hostedzone/${data.aws_route53_zone.public.zone_id}" },
      { Effect = "Allow", Action = ["route53:GetHealthCheckStatus", "route53:GetChange"], Resource = "*" },
      { Effect = "Allow", Action = ["sns:Publish"], Resource = aws_sns_topic.dr.arn },
      { Effect = "Allow", Action = ["states:StartExecution"], Resource = local.failover_sm_arn },
      { Effect = "Allow", Action = ["cloudwatch:PutMetricData"], Resource = "*" },
      # best-effort fencing of the primary region: stop the CRP instances there (tag-scoped)
      { Effect = "Allow", Action = ["ec2:StopInstances"], Resource = "arn:aws:ec2:${var.primary_region}:${local.account_id}:instance/*", Condition = { StringEquals = { "aws:ResourceTag/Project" = var.name_prefix } } },
    ]
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  provider          = aws.dr
  for_each          = toset(["actions", "probe", "drs-monitor"])
  name              = "/aws/lambda/${local.fn_prefix}-${each.value}"
  retention_in_days = 30
}

resource "aws_lambda_function" "actions" {
  provider         = aws.dr
  function_name    = "${local.fn_prefix}-actions"
  role             = aws_iam_role.controller.arn
  runtime          = "python3.12"
  handler          = "actions.handler"
  filename         = data.archive_file.controller.output_path
  source_code_hash = data.archive_file.controller.output_base64sha256
  timeout          = 180
  memory_size      = 256
  environment {
    variables = {
      TABLE       = aws_dynamodb_table.state.name
      SNS_TOPIC   = aws_sns_topic.dr.arn
      NAME_PREFIX = var.name_prefix
    }
  }
  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy_attachment.controller_basic]
}

# Runs in the DR VPC so it can ask Patroni on the primary database nodes over the inter-region peering.
resource "aws_lambda_function" "probe" {
  provider         = aws.dr
  function_name    = "${local.fn_prefix}-probe"
  role             = aws_iam_role.controller.arn
  runtime          = "python3.12"
  handler          = "probe.handler"
  filename         = data.archive_file.controller.output_path
  source_code_hash = data.archive_file.controller.output_base64sha256
  timeout          = 55
  memory_size      = 256
  vpc_config {
    subnet_ids         = module.vpc_dr.app_subnet_ids
    security_group_ids = [aws_security_group.probe.id]
  }
  environment {
    variables = {
      TABLE          = aws_dynamodb_table.state.name
      SNS_TOPIC      = aws_sns_topic.dr.arn
      FAIL_THRESHOLD = tostring(var.probe_failure_threshold)
      FAILOVER_SM    = local.failover_sm_arn
    }
  }
  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy_attachment.controller_basic, module.vpc_dr, aws_route.dr_to_primary]
}

resource "aws_lambda_function" "drs_monitor" {
  provider         = aws.dr
  function_name    = "${local.fn_prefix}-drs-monitor"
  role             = aws_iam_role.controller.arn
  runtime          = "python3.12"
  handler          = "drs_monitor.handler"
  filename         = data.archive_file.controller.output_path
  source_code_hash = data.archive_file.controller.output_base64sha256
  timeout          = 60
  memory_size      = 128
  depends_on       = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy_attachment.controller_basic]
}

# ---------------------------------------------------------------- schedules
resource "aws_cloudwatch_event_rule" "probe" {
  provider            = aws.dr
  name                = "${local.fn_prefix}-probe"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "probe" {
  provider = aws.dr
  rule     = aws_cloudwatch_event_rule.probe.name
  arn      = aws_lambda_function.probe.arn
}

resource "aws_lambda_permission" "probe" {
  provider      = aws.dr
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.probe.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.probe.arn
}

resource "aws_cloudwatch_event_rule" "drs_monitor" {
  provider            = aws.dr
  name                = "${local.fn_prefix}-drs-monitor"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "drs_monitor" {
  provider = aws.dr
  rule     = aws_cloudwatch_event_rule.drs_monitor.name
  arn      = aws_lambda_function.drs_monitor.arn
}

resource "aws_lambda_permission" "drs_monitor" {
  provider      = aws.dr
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.drs_monitor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.drs_monitor.arn
}

# ---------------------------------------------------------------- Step Functions
data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sfn" {
  provider           = aws.dr
  name               = "${var.name_prefix}-sfn"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

resource "aws_iam_role_policy" "sfn" {
  provider = aws.dr
  name     = "invoke-actions"
  role     = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "lambda:InvokeFunction", Resource = [aws_lambda_function.actions.arn, "${aws_lambda_function.actions.arn}:*"] },
      { Effect = "Allow", Action = ["logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery", "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutResourcePolicy", "logs:DescribeResourcePolicies", "logs:DescribeLogGroups", "logs:PutLogEvents", "logs:CreateLogStream"], Resource = "*" },
    ]
  })
}

resource "aws_cloudwatch_log_group" "sfn" {
  provider          = aws.dr
  name              = "/aws/vendedlogs/states/${var.name_prefix}"
  retention_in_days = 90
}

locals {
  fn = aws_lambda_function.actions.arn

  lambda_retry = [{
    ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
    IntervalSeconds = 2
    MaxAttempts     = 3
    BackoffRate     = 2
  }]
  catch_abort = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "Abort" }]
  is_drill    = { And = [{ Variable = "$.drill", IsPresent = true }, { Variable = "$.drill", BooleanEquals = true }] }

  waves      = ["db", "api", "web"]
  next_after = { db = "Start_api", api = "Start_web", web = "AfterWeb" }

  wave_states = merge([for w in local.waves : {
    "Start_${w}" = {
      Type       = "Task"
      Resource   = local.fn
      Parameters = { action = "start_recovery", wave = w, "ctx.$" = "$", "execution.$" = "$$.Execution.Name" }
      ResultPath = "$.job_${w}"
      Retry      = local.lambda_retry
      Catch      = local.catch_abort
      Next       = "Wait_${w}"
    }
    "Wait_${w}" = { Type = "Wait", Seconds = 20, Next = "Check_${w}" }
    "Check_${w}" = {
      Type       = "Task"
      Resource   = local.fn
      Parameters = { action = "check_job", "job_id.$" = "$.job_${w}.job_id" }
      ResultPath = "$.chk_${w}"
      Retry      = local.lambda_retry
      Catch      = local.catch_abort
      Next       = "Done_${w}"
    }
    "Done_${w}" = {
      Type = "Choice"
      Choices = [
        { Variable = "$.chk_${w}.failed", BooleanEquals = true, Next = "Abort" },
        { Variable = "$.chk_${w}.done", BooleanEquals = true, Next = "Validate_${w}" },
      ]
      Default = "Wait_${w}"
    }
    "Validate_${w}" = {
      Type       = "Task"
      Resource   = local.fn
      Parameters = { action = "validate", wave = w, "instances.$" = "$.chk_${w}.instances" }
      ResultPath = "$.val_${w}"
      Retry      = concat([{ ErrorEquals = ["ValidationFailed"], IntervalSeconds = 20, MaxAttempts = 18, BackoffRate = 1 }], local.lambda_retry)
      Catch      = local.catch_abort
      Next       = local.next_after[w]
    }
  }]...)

  failover_states = merge(local.wave_states, {
    NeedApproval = {
      Type    = "Choice"
      Choices = [merge(local.is_drill, { Next = "AcquireLock" })]
      Default = var.require_approval ? "Approval" : "AcquireLock"
    }
    Approval = {
      Type     = "Task"
      Resource = "arn:aws:states:::lambda:invoke.waitForTaskToken"
      Parameters = {
        FunctionName = local.fn
        Payload      = { action = "request_approval", kind = "failover", "token.$" = "$$.Task.Token", "ctx.$" = "$", "execution.$" = "$$.Execution.Name" }
      }
      TimeoutSeconds = var.approval_timeout_seconds
      ResultPath     = "$.approval"
      Catch = [
        { ErrorEquals = ["States.Timeout"], ResultPath = "$.error", Next = var.auto_approve_on_timeout ? "AcquireLock" : "Abort" },
        { ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "Abort" },
      ]
      Next = "AcquireLock"
    }
    AcquireLock = {
      Type       = "Task"
      Resource   = local.fn
      Parameters = { action = "acquire_lock", "ctx.$" = "$", "execution.$" = "$$.Execution.Name" }
      ResultPath = "$.lock"
      Retry      = local.lambda_retry
      Catch = [
        { ErrorEquals = ["LockHeld"], ResultPath = "$.error", Next = "LockHeldEnd" },
        { ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "Abort" },
      ]
      Next = "FenceChoice"
    }
    LockHeldEnd = { Type = "Fail", Error = "LockHeld", Cause = "Another failover owns the DR lock" }
    FenceChoice = {
      Type    = "Choice"
      Choices = [merge(local.is_drill, { Next = "Start_db" })]
      Default = "Fence"
    }
    Fence = {
      Type           = "Task"
      Resource       = local.fn
      Parameters     = { action = "fence_primary" }
      ResultPath     = "$.fence"
      TimeoutSeconds = 170
      Catch          = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.fence_error", Next = "Start_db" }] # best effort
      Next           = "Start_db"
    }
    AfterWeb = {
      Type    = "Choice"
      Choices = [merge(local.is_drill, { Next = "TerminateDrill" })]
      Default = "Register"
    }
    Register = {
      Type       = "Task"
      Resource   = local.fn
      Parameters = { action = "register_targets", "instances.$" = "$.chk_web.instances" }
      ResultPath = "$.reg"
      Retry      = local.lambda_retry
      Catch      = local.catch_abort
      Next       = "E2E"
    }
    E2E = {
      Type       = "Task"
      Resource   = local.fn
      Parameters = { action = "validate_e2e" }
      ResultPath = "$.e2e"
      Retry      = concat([{ ErrorEquals = ["ValidationFailed"], IntervalSeconds = 20, MaxAttempts = 15, BackoffRate = 1 }], local.lambda_retry)
      Catch      = local.catch_abort
      Next       = "SwitchDNS"
    }
    SwitchDNS = {
      Type       = "Task"
      Resource   = local.fn
      Parameters = { action = "switch_dns", target = "dr" }
      ResultPath = "$.dns"
      Retry      = local.lambda_retry
      Catch      = local.catch_abort
      Next       = "Finalize"
    }
    TerminateDrill = {
      Type       = "Task"
      Resource   = local.fn
      Parameters = { action = "terminate_drill", "ctx.$" = "$" }
      ResultPath = "$.terminated"
      Retry      = local.lambda_retry
      Catch      = local.catch_abort
      Next       = "Finalize"
    }
    Finalize = {
      Type       = "Task"
      Resource   = local.fn
      Parameters = { action = "finalize", "ctx.$" = "$", "execution.$" = "$$.Execution.Name" }
      ResultPath = "$.final"
      Retry      = local.lambda_retry
      End        = true
    }
    Abort = {
      Type       = "Task"
      Resource   = local.fn
      Parameters = { action = "abort", "ctx.$" = "$" }
      ResultPath = "$.aborted"
      Next       = "Failed"
    }
    Failed = { Type = "Fail", Error = "FailoverFailed", Cause = "See DynamoDB last_error and the execution history; the DR origin was NOT enabled." }
  })
}

resource "aws_sfn_state_machine" "failover" {
  provider = aws.dr
  name     = local.failover_sm_name
  role_arn = aws_iam_role.sfn.arn
  definition = jsonencode({
    Comment = "Primary region -> DR region disaster recovery with AWS Elastic Disaster Recovery. Input: {\"drill\": false, \"trigger\": \"manual\"}"
    StartAt = "NeedApproval"
    States  = local.failover_states
  })
  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }
}

resource "aws_sfn_state_machine" "failback" {
  provider = aws.dr
  name     = local.failback_sm_name
  role_arn = aws_iam_role.sfn.arn
  definition = jsonencode({
    Comment = "Controlled failback DR region -> primary region. Re-protect and sync the DR instances back to the primary region BEFORE starting this (see docs/runbooks.md)."
    StartAt = "Precheck"
    States = {
      Precheck = {
        Type       = "Task"
        Resource   = local.fn
        Parameters = { action = "failback_precheck" }
        ResultPath = "$.precheck"
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "FailbackFailed" }]
        Next       = "Approval"
      }
      Approval = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke.waitForTaskToken"
        Parameters = {
          FunctionName = local.fn
          Payload      = { action = "request_approval", kind = "failback", "token.$" = "$$.Task.Token", "ctx.$" = "$", "execution.$" = "$$.Execution.Name" }
        }
        TimeoutSeconds = 86400
        ResultPath     = "$.approval"
        Catch          = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "FailbackFailed" }]
        Next           = "SwitchDNS"
      }
      SwitchDNS = {
        Type       = "Task"
        Resource   = local.fn
        Parameters = { action = "switch_dns", target = "primary" }
        ResultPath = "$.dns"
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "FailbackFailed" }]
        Next       = "Finalize"
      }
      Finalize = {
        Type       = "Task"
        Resource   = local.fn
        Parameters = { action = "failback_finalize" }
        ResultPath = "$.final"
        End        = true
      }
      FailbackFailed = { Type = "Fail", Error = "FailbackFailed", Cause = "Failback stopped; production stays in the DR region. See the execution history." }
    }
  })
  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }
}

# ---------------------------------------------------------------- alarms
resource "aws_cloudwatch_metric_alarm" "drs_unhealthy" {
  provider            = aws.dr
  alarm_name          = "${var.name_prefix}-drs-replication-unhealthy"
  namespace           = "CRP/DRS"
  metric_name         = "UnhealthyServers"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.dr.arn]
  alarm_description   = "At least one DRS source server is not in CONTINUOUS replication (stalled/disconnected/initial sync)."
}

resource "aws_cloudwatch_metric_alarm" "drs_lag" {
  provider            = aws.dr
  alarm_name          = "${var.name_prefix}-drs-lag-high"
  namespace           = "CRP/DRS"
  metric_name         = "MaxLagSeconds"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.drs_max_lag_seconds
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.dr.arn]
  alarm_description   = "DRS replication lag exceeds the RPO budget."
}

resource "aws_cloudwatch_metric_alarm" "workflow_failed" {
  provider            = aws.dr
  alarm_name          = "${var.name_prefix}-failover-workflow-failed"
  namespace           = "AWS/States"
  metric_name         = "ExecutionsFailed"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  dimensions          = { StateMachineArn = aws_sfn_state_machine.failover.arn }
  alarm_actions       = [aws_sns_topic.dr.arn]
}
