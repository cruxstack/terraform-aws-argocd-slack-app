# =================================================================== locals ===

locals {
  enabled   = module.this.enabled
  role_name = coalesce(var.role_name, "${var.cluster_name}-argocd-slack")
}

data "aws_eks_cluster" "this" {
  count = local.enabled ? 1 : 0

  name = var.cluster_name
}

# --------------------------------------------------------------------- iam ---

# the function assumes this role, then reaches the cluster's api through the
# access entry below
resource "aws_iam_role" "this" {
  count = local.enabled ? 1 : 0

  name        = local.role_name
  description = "Lets argocd-slack-app read Argo CD apps in ${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.lambda_role_arn }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = module.this.tags
}

resource "aws_iam_role_policy" "this" {
  count = local.enabled ? 1 : 0

  name = "describe-cluster"
  role = aws_iam_role.this[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "eks:DescribeCluster"
      Resource = data.aws_eks_cluster.this[0].arn
    }]
  })
}

resource "aws_eks_access_entry" "this" {
  count = local.enabled ? 1 : 0

  cluster_name      = var.cluster_name
  principal_arn     = aws_iam_role.this[0].arn
  kubernetes_groups = [var.kubernetes_group]
  type              = "STANDARD"

  tags = module.this.tags
}

# -------------------------------------------------------------- kubernetes ---

# read-only: argo cd apps and what explains their health; no secrets or
# configmaps, and pod logs only when read_logs is set
resource "kubernetes_cluster_role_v1" "this" {
  count = local.enabled ? 1 : 0

  metadata {
    name = var.kubernetes_group
  }

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["applications"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["rollouts"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "events"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "replicasets", "statefulsets", "daemonsets"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = ["autoscaling"]
    resources  = ["horizontalpodautoscalers"]
    verbs      = ["get", "list"]
  }

  dynamic "rule" {
    for_each = var.read_logs ? [1] : []

    content {
      api_groups = [""]
      resources  = ["pods/log"]
      verbs      = ["get"]
    }
  }
}

resource "kubernetes_cluster_role_binding_v1" "this" {
  count = local.enabled ? 1 : 0

  metadata {
    name = var.kubernetes_group
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.this[0].metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = var.kubernetes_group
  }
}
