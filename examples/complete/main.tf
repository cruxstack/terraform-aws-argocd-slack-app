provider "aws" {
  region = "us-east-1"
}

# the cluster-reader submodule creates kubernetes rbac, so it needs a provider
# for the cluster it grants access to
data "aws_eks_cluster" "this" {
  name = var.eks_cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = var.eks_cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

module "argocd_slack" {
  source = "../../"

  # naming context
  namespace   = "eg"
  environment = "ue1"
  stage       = "ops"
  name        = "argocd-slack"

  # argocd-slack-app release to build
  app_version = "v0.1.0"

  app_config = {
    # start in dry run to see the messages in the function's logs first
    dry_run = true
    channel = var.slack_channel

    # ping a user group when a prod app owned by it fails
    owners = {
      api = "S0123456789"
    }

    # annotations your applicationsets set from each app's own repo; without
    # them, messages link the application's source repo and revision
    annotations = {
      repo   = "example.com/app-repository"
      commit = "example.com/app-commit"
      pr     = "example.com/app-pr"
      title  = "example.com/app-commit-title"
    }

    # buttons on every message; {app}, {namespace}, {cluster}, {env}, {region}
    # and each cluster's vars are filled in
    links = [
      {
        text = "Logs"
        url  = "https://logs.example.com/search?cluster={metrics_cluster}&namespace={namespace}"
      },
      {
        text = "Metrics"
        url  = "https://grafana.example.com/d/k8s-namespace?var-cluster={metrics_cluster}&var-namespace={namespace}"
      },
    ]

    clusters = [
      {
        name       = "prod-use1"
        env        = "prod"
        region     = "us-east-1"
        cluster    = var.eks_cluster_name
        role_arn   = module.cluster_reader.role_arn
        argocd_url = var.argocd_url
        vars = {
          metrics_cluster = "prod-use1"
        }
      },
    ]
  }

  cluster_role_arns = [module.cluster_reader.role_arn]

  # the slack secrets live under this prefix; create them before the first
  # apply (see the readme)
  slack_config = {
    ssm_parameter_prefix = "/argocd-slack/"
  }

  digest_schedule = {
    timezone = "America/Chicago"
  }

  # run inside a vpc to reach private eks api endpoints
  # vpc_config = {
  #   vpc_id     = "vpc-0123456789abcdef0"
  #   subnet_ids = ["subnet-0123456789abcdef0", "subnet-0fedcba9876543210"]
  # }
}

# one per cluster, applied with that cluster's providers
module "cluster_reader" {
  source = "../../modules/cluster-reader"

  cluster_name    = var.eks_cluster_name
  lambda_role_arn = module.argocd_slack.role_arn
  read_logs       = false
}

# ---------------------------------------------------------------- variables ---

variable "eks_cluster_name" {
  type        = string
  description = "Name of the EKS cluster that runs Argo CD"
}

variable "argocd_url" {
  type        = string
  description = "URL of that cluster's Argo CD, such as https://argocd.example.com"
}

variable "slack_channel" {
  type        = string
  description = "Slack channel ID for deploy and incident messages, such as C0123456789"
}

# ------------------------------------------------------------------ outputs ---

output "slack_request_urls" {
  description = "Request URLs for the Slack app's manifest"
  value       = module.argocd_slack.slack_request_urls
}

output "ssm_parameter_prefix" {
  description = "SSM path for SLACK_BOT_TOKEN and SLACK_SIGNING_SECRET"
  value       = module.argocd_slack.ssm_parameter_prefix
}

output "function_name" {
  description = "Name of the Lambda function"
  value       = module.argocd_slack.function_name
}
