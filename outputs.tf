# ================================================================== lambda ===

output "function_name" {
  description = "Name of the Lambda function"
  value       = try(aws_lambda_function.this[0].function_name, null)
}

output "function_arn" {
  description = "ARN of the Lambda function"
  value       = try(aws_lambda_function.this[0].arn, null)
}

# --------------------------------------------------------------------- iam ---

output "role_arn" {
  description = "ARN of the function's IAM role; cluster readers trust it"
  value       = try(aws_iam_role.this[0].arn, null)
}

output "role_name" {
  description = "Name of the function's IAM role"
  value       = try(aws_iam_role.this[0].name, null)
}

# ------------------------------------------------------------- api gateway ---

output "api_endpoint" {
  description = "Base URL of the HTTP API that receives Slack's requests"
  value       = local.api_endpoint
}

output "slack_request_urls" {
  description = "Request URLs to put in the Slack app's manifest"
  value = local.api_endpoint == null ? null : {
    commands      = "${local.api_endpoint}/slack/commands"
    interactivity = "${local.api_endpoint}/slack/interactivity"
    events        = "${local.api_endpoint}/slack/events"
  }
}

# ------------------------------------------------------------------- state ---

output "table_name" {
  description = "Name of the DynamoDB table that keeps deploy, incident, and mute state"
  value       = try(aws_dynamodb_table.this[0].name, null)
}

# --------------------------------------------------------------------- ssm ---

output "setup_url" {
  description = "Installer page that creates and installs the Slack app, while app_config.setup.enabled is on"
  value       = local.enabled && var.app_config.setup.enabled ? "${local.api_endpoint}/setup" : null
}

output "ssm_parameter_prefix" {
  description = "SSM path of the Slack credentials (SLACK_BOT_TOKEN, SLACK_SIGNING_SECRET, SLACK_CLIENT_ID, SLACK_CLIENT_SECRET, SLACK_TEAM)"
  value       = local.enabled ? local.ssm_parameter_prefix : null
}
