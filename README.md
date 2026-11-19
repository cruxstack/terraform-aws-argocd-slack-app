# terraform-aws-argocd-slack-app

Terraform module that deploys
[argocd-slack-app](https://github.com/cruxstack/argocd-slack-app) to AWS Lambda:
Argo CD deploys and incidents in Slack, one message each, edited in place as
they progress or recover. It includes an API Gateway HTTP API for the Slack
app's requests, a DynamoDB table for state, EventBridge Scheduler schedules,
and a submodule that gives the function read-only access to each EKS cluster.

## Features

- **One message per deploy** - Syncing, rolling out, healthy or failed, all in
  one message that updates as the deploy moves, with the timeline in its thread
- **One message per incident** - Opens after an app stays unhealthy past a
  grace period, explains the failure from pods, events, and hook jobs, and
  turns green with the downtime when the app recovers
- **No repeats** - Brief blips are dropped, flaps reopen the same message, and
  apps that are already failing when a cluster joins are summarised once
- **Mutes from Slack** - Per app, cluster, or environment, with an expiry, from
  message buttons, a modal, `/argocd`, or the app's Home tab
- **Daily digest** - Apps unhealthy for longer than a day, instead of repeats
- **Web installer** - A setup page creates the Slack app from its manifest and
  installs it with OAuth; no URLs or secrets to copy by hand
- **Read-only cluster access** - The function assumes a role per cluster that an
  EKS access entry maps to a read-only ClusterRole; nothing runs in the cluster
- **Secrets in SSM** - The Slack bot token and signing secret are SecureString
  parameters the function reads at startup, never in Terraform state

## Requirements

| Name       | Version     |
| ---------- | ----------- |
| terraform  | `>= 1.7`    |
| aws        | `>= 6.72.0` |
| buildkit   | `>= 0.0.2`  |
| kubernetes | `>= 2.0`    |

`kubernetes` is needed only by the `cluster-reader` submodule.

The module builds the function from source with the
[cruxstack/buildkit](https://registry.terraform.io/providers/cruxstack/buildkit)
provider, which needs a BuildKit endpoint where Terraform runs: Docker Desktop,
OrbStack, or Colima, `BUILDKIT_HOST`, or an embedded rootless `buildkitd` on
Linux.

## Usage

```hcl
module "argocd_slack" {
  source = "github.com/cruxstack/terraform-aws-argocd-slack-app?ref=v0.1.0"

  name = "argocd-slack"

  app_config = {
    channel = "C0123456789"
    setup   = { enabled = true } # first deploy only
    clusters = [
      {
        name       = "prod-use1"
        env        = "prod"
        region     = "us-east-1"
        cluster    = "prod-use1"
        role_arn   = module.cluster_reader_prod.role_arn
        argocd_url = "https://argocd.example.com"
      },
    ]
  }

  cluster_role_arns = [module.cluster_reader_prod.role_arn]
}

# in the cluster's account, with a kubernetes provider for that cluster
module "cluster_reader_prod" {
  source = "github.com/cruxstack/terraform-aws-argocd-slack-app//modules/cluster-reader?ref=v0.1.0"

  cluster_name    = "prod-use1"
  lambda_role_arn = module.argocd_slack.role_arn
}
```

See [examples/complete](examples/complete) for every option.

### Setting up

1. Apply this module with `app_config.setup.enabled = true`, then the
   `cluster-reader` submodule for each cluster. The reader's trust policy names
   the function's role, so it must exist first.
2. Open the `setup_url` output. Paste a Slack app configuration token (from
   [api.slack.com/apps](https://api.slack.com/apps) → *Your App Configuration
   Tokens*) and the page creates the app with every URL filled in, or follow
   its link to create the app yourself from a prefilled manifest and paste the
   credentials back.
3. Click **Install to Slack**. The callback saves the bot token. Every
   credential lands in SSM Parameter Store under the prefix (`/<id>/` by
   default), never in Terraform state.
4. Invite the bot to its channels, set `app_config.setup.enabled = false` and
   apply again, which also drops the function's write access to SSM.

Start with `app_config.dry_run = true` to see the messages in the function's
logs, or `app_config.channel_override` to send every cluster to a test channel.

To set the app up by hand instead, create it from the manifest in
[argocd-slack-app](https://github.com/cruxstack/argocd-slack-app#slack-app),
write `SLACK_BOT_TOKEN` and `SLACK_SIGNING_SECRET` under the prefix yourself, and
use the `slack_request_urls` outputs in the manifest.

### Reaching the clusters

The function calls each cluster's Kubernetes API with a token for the reader
role. A cluster with a public endpoint open to the internet needs nothing more.
For a private endpoint, or one limited to some CIDRs, run the function in a VPC
that can reach it with `vpc_config`, and give that VPC a route to Slack, STS,
EKS, and DynamoDB.

### Configuration

`app_config` is passed to the function as JSON. Every field except `clusters`
is optional; the app's README describes each one.

| Field              | Default                                        | What it does                                                                                                                             |
| ------------------ | ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `channel`          | `""`                                           | Slack channel for clusters that don't set their own                                                                                      |
| `channel_override` | `""`                                           | send every cluster to this channel, for testing                                                                                          |
| `dry_run`          | `false`                                        | log Slack calls instead of making them                                                                                                   |
| `timezone`         | `"UTC"`                                        | zone for message times and the digest's date                                                                                             |
| `watch_seconds`    | `55`                                           | how long each poll watches for changes; keep it under a minute                                                                           |
| `rich_blocks`      | `true`                                         | use the newer Block Kit blocks; the app falls back if Slack refuses them                                                                 |
| `preview_prefix`   | `"preview-"`                                   | apps with this prefix are flagged for cleanup in the digest when stuck                                                                   |
| `grace`            | `5m`, `10m`, `15m`, `10m`, `15m`, `24h`, `72h` | `incident`, `autoscaler`, `flap`, `deploy_window`, `stall`, `long_running`, `preview_cleanup`                                            |
| `owners`           | `{}`                                           | app name to Slack user or user group ID, mentioned on prod failures                                                                      |
| `annotations`      | `""`                                           | Application annotations holding `repo`, `commit`, `version`, `actor`, `approved_by`, `pr`, `title`, `run_url`, `changes`                 |
| `scm`              | GitHub URLs                                    | `commit_url`, `pr_url`, `compare_url` and `version_url` (off) templates with `{repo}`, `{commit}`, `{pr}`, `{from}`, `{to}`, `{version}` |
| `links`            | `[]`                                           | buttons on every message, as `text` and `url` templates                                                                                  |
| `setup`            | off                                            | the installer: `enabled`, `app_name` (`Argo CD`), `command` (`/argocd`), `base_url`                                                      |
| `clusters`         | n/a                                            | the Argo CD instances to watch; see below                                                                                                |

Each cluster takes `name` (as people type it in `/argocd mute`), `cluster` (the
EKS cluster name), `role_arn`, `argocd_url`, and optionally `env`, `region`,
`namespace` (default `argocd`), `channel`, `enabled` (default `true`),
`log_lines` (show one redacted error line from a crashed container; needs a
reader with `read_logs`), `links` (instead of the global ones), and `vars`.

Link templates can use `{app}`, `{namespace}`, `{cluster}`, `{env}`,
`{region}`, and the cluster's `vars`. Lambda limits the function's whole
environment to 4 KB, so put links in `app_config.links` once and keep each
cluster's differences in its `vars`.

## Inputs

In addition to the variables documented below, this module includes several
other optional variables (e.g., `name`, `tags`, etc.) provided by the
`cloudposse/label/null` module. Please refer to its [documentation](https://registry.terraform.io/modules/cloudposse/label/null/latest)
for more details on these variables.

| Name                    | Description                                                                                                           | Type           | Default                                               | Required |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------- | -------------- | ----------------------------------------------------- | -------- |
| `app_config`            | argocd-slack-app's configuration; see [Configuration](#configuration)                                                 | `object`       | n/a                                                   | yes      |
| `app_version`           | git tag, branch, or commit of argocd-slack-app to build; `latest` builds its default branch                           | `string`       | `"v0.1.0"`                                            | no       |
| `app_repo`              | git URL of the argocd-slack-app source                                                                                | `string`       | `"https://github.com/cruxstack/argocd-slack-app.git"` | no       |
| `app_force_rebuild_id`  | change to force a rebuild of the function's code                                                                      | `string`       | `""`                                                  | no       |
| `slack_config`          | `ssm_parameter_prefix` of the Slack parameters (default `/<id>/`)                                                     | `object`       | `{}`                                                  | no       |
| `cluster_role_arns`     | reader roles the function may assume; wildcards allowed                                                               | `list(string)` | `[]`                                                  | no       |
| `poll_schedule`         | `enabled`, `expression` (default `rate(1 minute)`)                                                                    | `object`       | `{}`                                                  | no       |
| `digest_schedule`       | `enabled`, `expression` (default `cron(30 9 ? * MON-FRI *)`), `timezone` (default `UTC`)                              | `object`       | `{}`                                                  | no       |
| `lambda_config`         | `log_level` (`info`), `memory_size` (256), `timeout` (75), `architecture` (`arm64`), `reserved_concurrent_executions` | `object`       | `{}`                                                  | no       |
| `vpc_config`            | `vpc_id` and `subnet_ids` to run the function in                                                                      | `object`       | `null`                                                | no       |
| `kms_key_arn`           | key for the logs, the table, and the Slack parameters                                                                 | `string`       | `null`                                                | no       |
| `log_retention_days`    | days to keep the function's and API's logs                                                                            | `number`       | `30`                                                  | no       |
| `alarm_actions`         | actions for the error and missing-heartbeat alarms                                                                    | `list(string)` | `[]`                                                  | no       |
| `iam_policy_statements` | more statements for the function's role                                                                               | `list(object)` | `[]`                                                  | no       |

## Outputs

| Name                   | Description                                                      |
| ---------------------- | ---------------------------------------------------------------- |
| `setup_url`            | installer page, while `app_config.setup.enabled` is on           |
| `slack_request_urls`   | `commands`, `interactivity`, and `events` URLs for the Slack app |
| `api_endpoint`         | base URL of the HTTP API                                         |
| `role_arn`             | ARN of the function's role; give it to each cluster reader       |
| `role_name`            | name of the function's role                                      |
| `function_name`        | name of the Lambda function                                      |
| `function_arn`         | ARN of the Lambda function                                       |
| `table_name`           | name of the DynamoDB table                                       |
| `ssm_parameter_prefix` | SSM path of the Slack credentials                                |

## Cluster Reader

[modules/cluster-reader](modules/cluster-reader) creates, for one EKS cluster,
an IAM role only the function can assume, an EKS access entry, and a read-only
ClusterRole: Applications, pods, events, workloads, jobs, HPAs, and Argo
Rollouts, and pod logs only with `read_logs = true`. No secrets, ConfigMaps, or
writes. Apply it with the cluster account's AWS provider and a Kubernetes
provider for the cluster.

## Architecture

```
+------------------+                         +------------------+
|   EventBridge    |  {"job": "poll"}        |    Slack app     |
|   Scheduler      |  {"job": "digest"}      | buttons, /argocd |
+--------+---------+                         +--------+---------+
         |                                            |
         |                                            | signed requests
         |                                            v
         |                                  +---------+--------+    +---------+
         |                                  |   API Gateway    |    |   SSM   |
         |                                  |   HTTP API       |    | secrets |
         |                                  +---------+--------+    +----+----+
         |                                            |                  |
         +---------------------+----------------------+                  |
                               |                                         |
                               v                                         |
                    +----------+---------+     +--------------+          |
                    |       Lambda       +---->|   DynamoDB   |          |
                    |  argocd-slack-app  |     |    state     |          |
                    +----+----------+----+     +--------------+          |
                         |          ^                                    |
                         |          +------------------------------------+
            assume role  |
            per cluster  v                       chat.postMessage / update
              +----------+---------+            +-------------------------+
              |  EKS API (read)    |            |        Slack API        |
              |  Argo CD apps,     |            +-------------------------+
              |  pods, events      |
              +--------------------+
```

## License

MIT Licensed. See [LICENSE](LICENSE) for full details.
