# ===================================================================== app ===

variable "app_version" {
  description = "Git tag, branch, or commit of argocd-slack-app to build. `latest` builds its default branch, which can include breaking changes."
  type        = string
  default     = "v0.1.0"

  validation {
    condition     = length(trimspace(var.app_version)) > 0
    error_message = "app_version must not be empty."
  }
}

variable "app_repo" {
  description = "Git URL of the argocd-slack-app source to build."
  type        = string
  default     = "https://github.com/cruxstack/argocd-slack-app.git"
}

variable "app_force_rebuild_id" {
  description = "Change this value to force a rebuild of the function's code."
  type        = string
  default     = ""
}

variable "app_config" {
  description = "Configuration of argocd-slack-app, passed to the function as JSON in `ARGOCD_SLACK_CONFIG`. See the README for each field."
  type = object({
    dry_run          = optional(bool, false)
    channel          = optional(string, "")
    channel_override = optional(string, "")
    timezone         = optional(string, "UTC")
    watch_seconds    = optional(number, 55)
    rich_blocks      = optional(bool, true)
    preview_prefix   = optional(string, "preview-")
    grace = optional(object({
      incident        = optional(string, "5m")
      autoscaler      = optional(string, "10m")
      flap            = optional(string, "15m")
      deploy_window   = optional(string, "10m")
      stall           = optional(string, "15m")
      long_running    = optional(string, "24h")
      preview_cleanup = optional(string, "72h")
    }), {})
    owners = optional(map(string), {})
    annotations = optional(object({
      repo    = optional(string, "")
      commit  = optional(string, "")
      actor   = optional(string, "")
      pr      = optional(string, "")
      title   = optional(string, "")
      run_url = optional(string, "")
    }), {})
    scm = optional(object({
      commit_url = optional(string, "https://github.com/{repo}/commit/{commit}")
      pr_url     = optional(string, "https://github.com/{repo}/pull/{pr}")
    }), {})
    links = optional(list(object({
      text = string
      url  = string
    })), [])
    clusters = list(object({
      name       = string
      cluster    = string
      env        = optional(string, "")
      region     = optional(string, "")
      role_arn   = optional(string, "")
      namespace  = optional(string, "argocd")
      argocd_url = optional(string, "")
      channel    = optional(string, "")
      enabled    = optional(bool, true)
      log_lines  = optional(bool, false)
      links = optional(list(object({
        text = string
        url  = string
      })), [])
      vars = optional(map(string), {})
    }))
  })

  validation {
    condition     = length(var.app_config.clusters) > 0
    error_message = "app_config.clusters must list at least one cluster."
  }

  validation {
    condition     = length(distinct([for c in var.app_config.clusters : c.name])) == length(var.app_config.clusters)
    error_message = "app_config.clusters names must be unique."
  }

  validation {
    condition = alltrue([
      for c in var.app_config.clusters : can(regex("^[a-z0-9][a-z0-9-]*$", c.name))
    ])
    error_message = "app_config.clusters names must be lowercase letters, digits, and dashes; people type them in /argocd mute."
  }

  validation {
    condition     = var.app_config.watch_seconds >= 1 && var.app_config.watch_seconds <= 58
    error_message = "app_config.watch_seconds must be between 1 and 58, inside the one-minute poll schedule."
  }

  validation {
    condition = alltrue([
      for c in var.app_config.clusters : c.channel != "" || var.app_config.channel != "" || var.app_config.channel_override != ""
    ])
    error_message = "every cluster needs a Slack channel: set app_config.channel, the cluster's channel, or channel_override."
  }
}

# ------------------------------------------------------------------- slack ---

variable "slack_config" {
  description = "Where the function finds its Slack credentials. Create SecureString parameters `<prefix>SLACK_BOT_TOKEN` and `<prefix>SLACK_SIGNING_SECRET` yourself; the module only lets the function read them. The prefix defaults to `/<id>/`."
  type = object({
    ssm_parameter_prefix = optional(string)
  })
  default = {}

  validation {
    condition     = var.slack_config.ssm_parameter_prefix == null || can(regex("^/.*/$", var.slack_config.ssm_parameter_prefix))
    error_message = "slack_config.ssm_parameter_prefix must start and end with a slash, such as /argocd-slack/."
  }
}

# ---------------------------------------------------------------- clusters ---

variable "cluster_role_arns" {
  description = "IAM roles the function may assume to read clusters, such as the `role_arn` outputs of the cluster-reader submodule. Wildcards are allowed."
  type        = list(string)
  default     = []
}

# --------------------------------------------------------------- schedules ---

variable "poll_schedule" {
  description = "Schedule that runs a poll: list, then watch, each cluster's Applications. Keep it at one minute; `app_config.watch_seconds` fills the rest."
  type = object({
    enabled    = optional(bool, true)
    expression = optional(string, "rate(1 minute)")
  })
  default = {}
}

variable "digest_schedule" {
  description = "Schedule of the daily summary of apps unhealthy for longer than `grace.long_running`."
  type = object({
    enabled    = optional(bool, true)
    expression = optional(string, "cron(30 9 ? * MON-FRI *)")
    timezone   = optional(string, "UTC")
  })
  default = {}
}

# ------------------------------------------------------------------ lambda ---

variable "lambda_config" {
  description = "Configuration of the Lambda function. A poll runs about `watch_seconds`, so keep the timeout above it."
  type = object({
    log_level                      = optional(string, "info")
    memory_size                    = optional(number, 256)
    timeout                        = optional(number, 75)
    architecture                   = optional(string, "arm64")
    reserved_concurrent_executions = optional(number, -1)
  })
  default = {}

  validation {
    condition     = contains(["debug", "info", "warn", "error"], var.lambda_config.log_level)
    error_message = "lambda_config.log_level must be one of: debug, info, warn, error."
  }

  validation {
    condition     = var.lambda_config.memory_size >= 128 && var.lambda_config.memory_size <= 10240
    error_message = "Lambda memory_size must be between 128 and 10240 MB."
  }

  validation {
    condition     = var.lambda_config.timeout >= 30 && var.lambda_config.timeout <= 900
    error_message = "Lambda timeout must be between 30 and 900 seconds."
  }

  validation {
    condition     = contains(["arm64", "x86_64"], var.lambda_config.architecture)
    error_message = "Lambda architecture must be arm64 or x86_64."
  }
}

variable "vpc_config" {
  description = "VPC to run the function in, for private EKS API endpoints. The function needs a route to Slack, STS, EKS, and DynamoDB from these subnets."
  type = object({
    vpc_id     = string
    subnet_ids = list(string)
  })
  default = null
}

variable "kms_key_arn" {
  description = "KMS key for the logs, the table, and the Slack parameters. The function may decrypt with it."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "Number of days to keep the function's and API Gateway's logs in CloudWatch Logs."
  type        = number
  default     = 30

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a valid CloudWatch Logs retention period."
  }
}

variable "alarm_actions" {
  description = "Actions, such as SNS topic ARNs, for the error and missing-heartbeat alarms."
  type        = list(string)
  default     = []
}

variable "iam_policy_statements" {
  description = "More IAM statements for the function's role."
  type = list(object({
    sid       = string
    actions   = list(string)
    resources = list(string)
  }))
  default = []
}
