# =================================================================== locals ===

locals {
  enabled = module.this.enabled

  aws_account_id  = data.aws_caller_identity.current.account_id
  aws_region_name = data.aws_region.current.region
  aws_partition   = data.aws_partition.current.partition

  goarch       = var.lambda_config.architecture == "arm64" ? "arm64" : "amd64"
  function_arn = "arn:${local.aws_partition}:lambda:${local.aws_region_name}:${local.aws_account_id}:function:${module.this.id}"

  ssm_parameter_prefix     = coalesce(var.slack_config.ssm_parameter_prefix, "/${module.this.id}/")
  ssm_parameter_arn_prefix = "arn:${local.aws_partition}:ssm:${local.aws_region_name}:${local.aws_account_id}:parameter${local.ssm_parameter_prefix}"

  # lambda allows 4 KB of environment in total; the config is most of it
  app_config_json = jsonencode(var.app_config)

  # the function gets the slack parameters' arns and reads them at startup, so
  # no secret is in its configuration or in terraform state
  lambda_environment = {
    LOG_LEVEL            = var.lambda_config.log_level
    SLACK_BOT_TOKEN      = "${local.ssm_parameter_arn_prefix}SLACK_BOT_TOKEN"
    SLACK_SIGNING_SECRET = "${local.ssm_parameter_arn_prefix}SLACK_SIGNING_SECRET"
    TABLE_NAME           = module.this.id
    ARGOCD_SLACK_CONFIG  = local.app_config_json
  }

  api_endpoint = local.enabled ? one(aws_apigatewayv2_api.this[*].api_endpoint) : null

  schedules = {
    poll = {
      enabled    = var.poll_schedule.enabled
      expression = var.poll_schedule.expression
      timezone   = "UTC"
      input      = jsonencode({ job = "poll" })
    }
    digest = {
      enabled    = var.digest_schedule.enabled
      expression = var.digest_schedule.expression
      timezone   = var.digest_schedule.timezone
      input      = jsonencode({ job = "digest" })
    }
  }
  active_schedules = { for k, v in local.schedules : k => v if local.enabled && v.enabled }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# ================================================================== lambda ===

data "buildkit_context" "app" {
  count = local.enabled ? 1 : 0

  path = abspath("${path.module}/assets/lambda-function")
}

# argocd-slack-app built at app_version for the function's architecture
resource "buildkit_artifact" "app" {
  count = local.enabled ? 1 : 0

  build_context     = abspath("${path.module}/assets/lambda-function")
  dockerfile        = "Dockerfile"
  target            = "package"
  artifact_src_path = "/tmp/package.zip"
  artifact_src_type = "zip"
  artifact_dst_path = "${path.module}/dist/${module.this.id}/package.zip"

  build_args = {
    APP_VERSION = var.app_version
    APP_REPO    = var.app_repo
    GOARCH      = local.goarch
  }

  triggers = {
    context          = data.buildkit_context.app[0].digest
    app_version      = var.app_version
    app_repo         = var.app_repo
    goarch           = local.goarch
    force_rebuild_id = var.app_force_rebuild_id
  }
}

resource "aws_lambda_function" "this" {
  count = local.enabled ? 1 : 0

  function_name                  = module.this.id
  description                    = "Argo CD deploys and incidents in Slack, one message each"
  role                           = aws_iam_role.this[0].arn
  handler                        = "bootstrap"
  runtime                        = "provided.al2023"
  memory_size                    = var.lambda_config.memory_size
  timeout                        = var.lambda_config.timeout
  reserved_concurrent_executions = var.lambda_config.reserved_concurrent_executions
  architectures                  = [var.lambda_config.architecture]

  filename         = buildkit_artifact.app[0].artifact_path
  source_code_hash = buildkit_artifact.app[0].artifact_sha256

  environment {
    variables = local.lambda_environment
  }

  dynamic "vpc_config" {
    for_each = var.vpc_config != null ? [var.vpc_config] : []

    content {
      subnet_ids         = vpc_config.value.subnet_ids
      security_group_ids = [aws_security_group.this[0].id]
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.app_config_json) < 3800
      error_message = "app_config is ${length(local.app_config_json)} bytes as JSON; Lambda allows 4 KB of environment in total. Put links in app_config.links once, with each cluster's differences in its vars, instead of repeating links per cluster."
    }

    precondition {
      condition     = var.lambda_config.timeout > var.app_config.watch_seconds + 10
      error_message = "lambda_config.timeout must be more than app_config.watch_seconds plus 10 seconds, so a poll can finish."
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.this,
    aws_iam_role_policy_attachment.vpc,
  ]

  tags = module.this.tags
}

resource "aws_security_group" "this" {
  count = local.enabled && var.vpc_config != null ? 1 : 0

  name        = module.this.id
  description = "Lambda function ${module.this.id}"
  vpc_id      = var.vpc_config.vpc_id
  tags        = module.this.tags
}

resource "aws_vpc_security_group_egress_rule" "https" {
  count = local.enabled && var.vpc_config != null ? 1 : 0

  security_group_id = aws_security_group.this[0].id
  description       = "HTTPS to Slack, AWS APIs, and EKS API endpoints"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_iam_role_policy_attachment" "vpc" {
  count = local.enabled && var.vpc_config != null ? 1 : 0

  role       = aws_iam_role.this[0].name
  policy_arn = "arn:${local.aws_partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# slack requests hand longer work to async invocations of the same function;
# the next poll repairs anything a failed job left behind, so no retries
resource "aws_lambda_function_event_invoke_config" "this" {
  count = local.enabled ? 1 : 0

  function_name                = aws_lambda_function.this[0].function_name
  maximum_retry_attempts       = 0
  maximum_event_age_in_seconds = 300
}

resource "aws_cloudwatch_log_group" "lambda" {
  count = local.enabled ? 1 : 0

  name              = "/aws/lambda/${module.this.id}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = module.this.tags
}

# =================================================================== state ===

resource "aws_dynamodb_table" "this" {
  count = local.enabled ? 1 : 0

  name                        = module.this.id
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "pk"
  range_key                   = "sk"
  deletion_protection_enabled = true

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  dynamic "server_side_encryption" {
    for_each = var.kms_key_arn != null ? [var.kms_key_arn] : []

    content {
      enabled     = true
      kms_key_arn = server_side_encryption.value
    }
  }

  tags = module.this.tags
}

# ============================================================= api gateway ===

resource "aws_apigatewayv2_api" "this" {
  count = local.enabled ? 1 : 0

  name          = module.this.id
  protocol_type = "HTTP"
  description   = "Slack requests for ${module.this.id}"

  tags = module.this.tags
}

resource "aws_apigatewayv2_stage" "this" {
  count = local.enabled ? 1 : 0

  api_id      = aws_apigatewayv2_api.this[0].id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway[0].arn
    format = jsonencode({
      requestId         = "$context.requestId"
      ip                = "$context.identity.sourceIp"
      requestTime       = "$context.requestTime"
      httpMethod        = "$context.httpMethod"
      path              = "$context.path"
      routeKey          = "$context.routeKey"
      status            = "$context.status"
      protocol          = "$context.protocol"
      responseLength    = "$context.responseLength"
      integrationStatus = "$context.integrationStatus"
      integrationError  = "$context.integrationErrorMessage"
    })
  }

  tags = module.this.tags
}

resource "aws_cloudwatch_log_group" "api_gateway" {
  count = local.enabled ? 1 : 0

  name              = "/aws/apigateway/${module.this.id}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = module.this.tags
}

resource "aws_apigatewayv2_integration" "this" {
  count = local.enabled ? 1 : 0

  api_id                 = aws_apigatewayv2_api.this[0].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.this[0].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "this" {
  for_each = local.enabled ? toset([
    "POST /slack/interactivity",
    "POST /slack/commands",
    "POST /slack/events",
    "GET /healthz",
  ]) : toset([])

  api_id    = aws_apigatewayv2_api.this[0].id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.this[0].id}"
}

resource "aws_lambda_permission" "api_gateway" {
  count = local.enabled ? 1 : 0

  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this[0].execution_arn}/*/*"
}

# =============================================================== schedules ===

# each schedule invokes the function with its job as the whole event
resource "aws_scheduler_schedule" "this" {
  for_each = local.active_schedules

  name                         = "${module.this.id}-${each.key}"
  description                  = "${each.key} job of ${module.this.id}"
  schedule_expression          = each.value.expression
  schedule_expression_timezone = each.value.timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.this[0].arn
    role_arn = aws_iam_role.scheduler[0].arn
    input    = each.value.input

    retry_policy {
      maximum_retry_attempts       = 0
      maximum_event_age_in_seconds = 60
    }
  }
}

resource "aws_iam_role" "scheduler" {
  count = length(local.active_schedules) > 0 ? 1 : 0

  name        = "${module.this.id}-scheduler"
  description = "Lets EventBridge Scheduler invoke ${module.this.id}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.aws_account_id } }
    }]
  })

  tags = module.this.tags
}

resource "aws_iam_role_policy" "scheduler" {
  count = length(local.active_schedules) > 0 ? 1 : 0

  name = "invoke"
  role = aws_iam_role.scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = [local.function_arn, "${local.function_arn}:*"]
    }]
  })
}

# --------------------------------------------------------------------- iam ---

resource "aws_iam_role" "this" {
  count = local.enabled ? 1 : 0

  name        = module.this.id
  description = "Role of the ${module.this.id} Lambda function"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow"
      Principal = { "Service" : "lambda.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = module.this.tags
}

data "aws_iam_policy_document" "this" {
  count = local.enabled ? 1 : 0

  statement {
    sid    = "CloudWatchLogsAccess"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.lambda[0].arn}:*"]
  }

  statement {
    sid       = "ReadSlackCredentials"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["${local.ssm_parameter_arn_prefix}*"]
  }

  statement {
    sid    = "State"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
      "dynamodb:BatchGetItem",
      "dynamodb:ConditionCheckItem",
    ]
    resources = [aws_dynamodb_table.this[0].arn]
  }

  statement {
    sid       = "EnqueueJobs"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [local.function_arn]
  }

  statement {
    sid       = "PublishHeartbeat"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["ArgoCDSlack"]
    }
  }

  dynamic "statement" {
    for_each = length(var.cluster_role_arns) > 0 ? [1] : []

    content {
      sid       = "AssumeClusterReaders"
      effect    = "Allow"
      actions   = ["sts:AssumeRole"]
      resources = var.cluster_role_arns
    }
  }

  dynamic "statement" {
    for_each = var.kms_key_arn != null ? [1] : []

    content {
      sid       = "UseKey"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [var.kms_key_arn]
    }
  }

  dynamic "statement" {
    for_each = var.iam_policy_statements

    content {
      sid       = statement.value.sid
      effect    = "Allow"
      actions   = statement.value.actions
      resources = statement.value.resources
    }
  }
}

resource "aws_iam_role_policy" "this" {
  count = local.enabled ? 1 : 0

  name   = module.this.id
  role   = aws_iam_role.this[0].id
  policy = data.aws_iam_policy_document.this[0].json
}

# ================================================================== alarms ===

resource "aws_cloudwatch_metric_alarm" "errors" {
  count = local.enabled ? 1 : 0

  alarm_name          = "${module.this.id}-errors"
  alarm_description   = "The ${module.this.id} Lambda function is failing"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.this[0].function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  ok_actions          = var.alarm_actions
  tags                = module.this.tags
}

# the function emits ArgoCDSlack/PollSucceeded, with no dimensions, after each
# poll that read every enabled cluster
resource "aws_cloudwatch_metric_alarm" "heartbeat" {
  count = local.enabled && var.poll_schedule.enabled ? 1 : 0

  alarm_name          = "${module.this.id}-heartbeat"
  alarm_description   = "${module.this.id} has not finished a poll in 5 minutes"
  namespace           = "ArgoCDSlack"
  metric_name         = "PollSucceeded"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = var.alarm_actions
  ok_actions          = var.alarm_actions
  tags                = module.this.tags
}
