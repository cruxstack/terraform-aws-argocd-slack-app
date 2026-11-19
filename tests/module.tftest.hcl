# Runs the module with mocked providers, so these tests need no AWS account
# and build nothing. Run with: terraform test

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }
  mock_data "aws_eks_cluster" {
    defaults = {
      arn = "arn:aws:eks:us-east-1:111122223333:cluster/prod-use1"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/test"
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:111122223333:log-group:mock"
    }
  }
  mock_resource "aws_dynamodb_table" {
    defaults = {
      arn = "arn:aws:dynamodb:us-east-1:111122223333:table/test"
    }
  }
  mock_resource "aws_apigatewayv2_api" {
    defaults = {
      api_endpoint  = "https://abc123.execute-api.us-east-1.amazonaws.com"
      execution_arn = "arn:aws:execute-api:us-east-1:111122223333:abc123"
    }
  }
  mock_resource "aws_lambda_function" {
    defaults = {
      arn        = "arn:aws:lambda:us-east-1:111122223333:function:test"
      invoke_arn = "arn:aws:apigateway:us-east-1:lambda:path/functions/test/invocations"
    }
  }
}

mock_provider "buildkit" {}

variables {
  name = "test"
  app_config = {
    channel = "C0123456789"
    clusters = [
      { name = "prod-use1", cluster = "prod-use1", env = "prod", role_arn = "arn:aws:iam::111122223333:role/prod-use1-argocd-slack" },
    ]
  }
}

run "defaults" {
  assert {
    condition = alltrue([
      aws_lambda_function.this[0].runtime == "provided.al2023",
      aws_lambda_function.this[0].handler == "bootstrap",
      aws_lambda_function.this[0].architectures[0] == "arm64",
      aws_lambda_function.this[0].timeout == 75,
      aws_lambda_function.this[0].source_code_hash == buildkit_artifact.app[0].artifact_sha256,
    ])
    error_message = "the function should run the arm64 go binary and redeploy when the artifact changes"
  }

  assert {
    condition = alltrue([
      buildkit_artifact.app[0].build_args.APP_VERSION == "v0.2.0",
      buildkit_artifact.app[0].build_args.APP_REPO == "https://github.com/cruxstack/argocd-slack-app.git",
      buildkit_artifact.app[0].build_args.GOARCH == "arm64",
      buildkit_artifact.app[0].artifact_dst_path == "./dist/test/package.zip",
    ])
    error_message = "the artifact should be built at the pinned version for arm64, at a path unique to the instance"
  }

  assert {
    condition = alltrue([
      toset(keys(aws_lambda_function.this[0].environment[0].variables)) == toset(["LOG_LEVEL", "SLACK_BOT_TOKEN", "SLACK_SIGNING_SECRET", "SLACK_CLIENT_ID", "SLACK_CLIENT_SECRET", "SLACK_TEAM", "SSM_KMS_KEY_ID", "TABLE_NAME", "ARGOCD_SLACK_CONFIG"]),
      aws_lambda_function.this[0].environment[0].variables.SLACK_BOT_TOKEN == "arn:aws:ssm:us-east-1:111122223333:parameter/test/SLACK_BOT_TOKEN",
      aws_lambda_function.this[0].environment[0].variables.SLACK_SIGNING_SECRET == "arn:aws:ssm:us-east-1:111122223333:parameter/test/SLACK_SIGNING_SECRET",
      aws_lambda_function.this[0].environment[0].variables.TABLE_NAME == "test",
      aws_lambda_function.this[0].environment[0].variables.LOG_LEVEL == "info",
    ])
    error_message = "the function should get exactly its five variables, with the slack secrets as parameter arns"
  }

  assert {
    condition = alltrue([
      jsondecode(aws_lambda_function.this[0].environment[0].variables.ARGOCD_SLACK_CONFIG).channel == "C0123456789",
      jsondecode(aws_lambda_function.this[0].environment[0].variables.ARGOCD_SLACK_CONFIG).timezone == "UTC",
      jsondecode(aws_lambda_function.this[0].environment[0].variables.ARGOCD_SLACK_CONFIG).grace.incident == "5m",
      jsondecode(aws_lambda_function.this[0].environment[0].variables.ARGOCD_SLACK_CONFIG).scm.commit_url == "https://github.com/{repo}/commit/{commit}",
      jsondecode(aws_lambda_function.this[0].environment[0].variables.ARGOCD_SLACK_CONFIG).scm.compare_url == "https://github.com/{repo}/compare/{from}...{to}",
      jsondecode(aws_lambda_function.this[0].environment[0].variables.ARGOCD_SLACK_CONFIG).annotations.changes == "",
      jsondecode(aws_lambda_function.this[0].environment[0].variables.ARGOCD_SLACK_CONFIG).clusters[0].namespace == "argocd",
      jsondecode(aws_lambda_function.this[0].environment[0].variables.ARGOCD_SLACK_CONFIG).clusters[0].enabled == true,
      jsondecode(aws_lambda_function.this[0].environment[0].variables.ARGOCD_SLACK_CONFIG).clusters[0].log_lines == false,
    ])
    error_message = "the config should reach the function as json with its defaults filled in"
  }

  assert {
    condition = alltrue([
      toset(keys(aws_apigatewayv2_route.this)) == toset(["POST /slack/interactivity", "POST /slack/commands", "POST /slack/events", "GET /healthz", "GET /setup", "POST /setup", "GET /slack/oauth/install", "GET /slack/oauth/callback"]),
      aws_apigatewayv2_stage.this[0].name == "$default",
      output.slack_request_urls.commands == "https://abc123.execute-api.us-east-1.amazonaws.com/slack/commands",
      output.slack_request_urls.interactivity == "https://abc123.execute-api.us-east-1.amazonaws.com/slack/interactivity",
      output.slack_request_urls.events == "https://abc123.execute-api.us-east-1.amazonaws.com/slack/events",
    ])
    error_message = "slack's request urls, the installer and the health check should be routed to the function"
  }

  assert {
    condition = alltrue([
      aws_scheduler_schedule.this["poll"].schedule_expression == "rate(1 minute)",
      aws_scheduler_schedule.this["poll"].target[0].input == jsonencode({ job = "poll" }),
      aws_scheduler_schedule.this["digest"].schedule_expression == "cron(30 9 ? * MON-FRI *)",
      aws_scheduler_schedule.this["digest"].schedule_expression_timezone == "UTC",
      aws_scheduler_schedule.this["digest"].target[0].input == jsonencode({ job = "digest" }),
    ])
    error_message = "the schedules should invoke the function with the poll and digest jobs"
  }

  assert {
    condition = alltrue([
      aws_dynamodb_table.this[0].hash_key == "pk",
      aws_dynamodb_table.this[0].range_key == "sk",
      aws_dynamodb_table.this[0].ttl[0].attribute_name == "ttl",
      aws_dynamodb_table.this[0].point_in_time_recovery[0].enabled,
      aws_dynamodb_table.this[0].deletion_protection_enabled,
      aws_lambda_function_event_invoke_config.this[0].maximum_retry_attempts == 0,
    ])
    error_message = "state should live in a protected, recoverable table, and async jobs should not retry"
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.this[0].statement :
      s.sid == "ReadSlackCredentials" && toset(s.resources) == toset(["arn:aws:ssm:us-east-1:111122223333:parameter/test/*"])
    ])
    error_message = "the function should read parameters under its prefix only"
  }

  assert {
    condition = alltrue([
      !anytrue([for s in data.aws_iam_policy_document.this[0].statement : s.sid == "AssumeClusterReaders"]),
      !anytrue([for s in data.aws_iam_policy_document.this[0].statement : s.sid == "UseKey"]),
      anytrue([
        for s in data.aws_iam_policy_document.this[0].statement :
        s.sid == "PublishHeartbeat" && contains(flatten([for c in s.condition : c.values]), "ArgoCDSlack")
      ]),
    ])
    error_message = "without cluster roles or a key, the policy should not grant them, and metrics should be limited to the heartbeat namespace"
  }

  assert {
    condition = alltrue([
      aws_cloudwatch_metric_alarm.heartbeat[0].namespace == "ArgoCDSlack",
      aws_cloudwatch_metric_alarm.heartbeat[0].metric_name == "PollSucceeded",
      aws_cloudwatch_metric_alarm.heartbeat[0].treat_missing_data == "breaching",
      aws_cloudwatch_metric_alarm.heartbeat[0].dimensions == null,
      length(aws_security_group.this) == 0,
      output.ssm_parameter_prefix == "/test/",
      output.setup_url == null,
      !anytrue([for st in data.aws_iam_policy_document.this[0].statement : st.sid == "SaveSlackCredentials"]),
    ])
    error_message = "a missing heartbeat should alarm, and nothing vpc-related should exist without vpc_config"
  }
}

run "cluster_roles_vpc_key_and_prefix" {
  variables {
    cluster_role_arns = ["arn:aws:iam::111122223333:role/*-argocd-slack"]
    slack_config      = { ssm_parameter_prefix = "/ops/argocd-slack/" }
    kms_key_arn       = "arn:aws:kms:us-east-1:111122223333:key/0123"
    lambda_config     = { architecture = "x86_64", log_level = "debug" }
    vpc_config = {
      vpc_id     = "vpc-0123456789abcdef0"
      subnet_ids = ["subnet-0123456789abcdef0"]
    }
  }

  assert {
    condition = alltrue([
      anytrue([
        for s in data.aws_iam_policy_document.this[0].statement :
        s.sid == "AssumeClusterReaders" && s.resources == toset(["arn:aws:iam::111122223333:role/*-argocd-slack"])
      ]),
      anytrue([
        for s in data.aws_iam_policy_document.this[0].statement :
        s.sid == "ReadSlackCredentials" && s.resources == toset(["arn:aws:ssm:us-east-1:111122223333:parameter/ops/argocd-slack/*"])
      ]),
      anytrue([for s in data.aws_iam_policy_document.this[0].statement : s.sid == "UseKey"]),
    ])
    error_message = "the function should assume the cluster roles, read the custom prefix, and use the key"
  }

  assert {
    condition = alltrue([
      aws_lambda_function.this[0].environment[0].variables.SLACK_BOT_TOKEN == "arn:aws:ssm:us-east-1:111122223333:parameter/ops/argocd-slack/SLACK_BOT_TOKEN",
      aws_lambda_function.this[0].environment[0].variables.LOG_LEVEL == "debug",
      buildkit_artifact.app[0].build_args.GOARCH == "amd64",
      length(aws_security_group.this) == 1,
      length(aws_iam_role_policy_attachment.vpc) == 1,
      aws_dynamodb_table.this[0].server_side_encryption[0].kms_key_arn == "arn:aws:kms:us-east-1:111122223333:key/0123",
    ])
    error_message = "the prefix, log level, architecture, vpc, and key should all apply"
  }
}

run "setup_on" {
  variables {
    app_config = {
      channel = "C0123456789"
      setup   = { enabled = true }
      clusters = [
        { name = "prod-use1", cluster = "prod-use1" },
      ]
    }
  }

  assert {
    condition = alltrue([
      anytrue([
        for st in data.aws_iam_policy_document.this[0].statement :
        st.sid == "SaveSlackCredentials" && contains(st.actions, "ssm:PutParameter") && toset(st.resources) == toset(["arn:aws:ssm:us-east-1:111122223333:parameter/test/*"])
      ]),
      output.setup_url == "${aws_apigatewayv2_api.this[0].api_endpoint}/setup",
      jsondecode(aws_lambda_function.this[0].environment[0].variables.ARGOCD_SLACK_CONFIG).setup.enabled == true,
    ])
    error_message = "with setup on, the function may write its slack credentials and the setup url is output"
  }
}

run "schedules_off" {
  variables {
    poll_schedule   = { enabled = false }
    digest_schedule = { enabled = false }
  }

  assert {
    condition = alltrue([
      length(aws_scheduler_schedule.this) == 0,
      length(aws_iam_role.scheduler) == 0,
      length(aws_cloudwatch_metric_alarm.heartbeat) == 0,
    ])
    error_message = "without schedules there should be no scheduler role and no heartbeat alarm"
  }
}

run "disabled" {
  variables {
    enabled = false
  }

  assert {
    condition = alltrue([
      length(aws_lambda_function.this) == 0,
      length(buildkit_artifact.app) == 0,
      length(aws_dynamodb_table.this) == 0,
      length(aws_apigatewayv2_api.this) == 0,
      length(aws_scheduler_schedule.this) == 0,
      output.slack_request_urls == null,
    ])
    error_message = "a disabled module should create nothing"
  }
}

# -------------------------------------------------------------- validation ---

run "rejects_config_over_the_env_limit" {
  command = plan

  variables {
    app_config = {
      channel = "C0123456789"
      clusters = [
        for i in range(30) : {
          name       = "cluster-${i}"
          cluster    = "cluster-${i}"
          argocd_url = "https://argocd-${i}.example.com"
          links = [
            { text = "Logs", url = "https://logs.example.com/search?cluster=cluster-${i}&namespace={namespace}" },
          ]
        }
      ]
    }
  }

  expect_failures = [aws_lambda_function.this]
}

run "rejects_duplicate_cluster_names" {
  command = plan

  variables {
    app_config = {
      channel = "C0123456789"
      clusters = [
        { name = "prod-use1", cluster = "a" },
        { name = "prod-use1", cluster = "b" },
      ]
    }
  }

  expect_failures = [var.app_config]
}

run "rejects_cluster_without_channel" {
  command = plan

  variables {
    app_config = {
      clusters = [{ name = "prod-use1", cluster = "a" }]
    }
  }

  expect_failures = [var.app_config]
}

run "rejects_timeout_shorter_than_a_poll" {
  command = plan

  variables {
    lambda_config = { timeout = 60 }
  }

  expect_failures = [aws_lambda_function.this]
}
