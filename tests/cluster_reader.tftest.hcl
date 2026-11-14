# Tests the cluster-reader submodule with mocked providers; no AWS account or
# cluster needed. Run with: terraform test

mock_provider "aws" {
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
}

mock_provider "kubernetes" {}

run "cluster_reader" {
  module {
    source = "./modules/cluster-reader"
  }

  variables {
    cluster_name    = "prod-use1"
    lambda_role_arn = "arn:aws:iam::111122223333:role/eg-ue1-ops-argocd-slack"
  }

  assert {
    condition = alltrue([
      aws_iam_role.this[0].name == "prod-use1-argocd-slack",
      jsondecode(aws_iam_role.this[0].assume_role_policy).Statement[0].Principal.AWS == "arn:aws:iam::111122223333:role/eg-ue1-ops-argocd-slack",
      jsondecode(aws_iam_role_policy.this[0].policy).Statement[0].Resource == "arn:aws:eks:us-east-1:111122223333:cluster/prod-use1",
      aws_eks_access_entry.this[0].kubernetes_groups == toset(["argocd-slack-reader"]),
      kubernetes_cluster_role_binding_v1.this[0].subject[0].name == "argocd-slack-reader",
    ])
    error_message = "only the function may assume the reader, which maps to the read-only group"
  }

  assert {
    condition = alltrue([
      !anytrue([for r in kubernetes_cluster_role_v1.this[0].rule : contains(r.resources, "pods/log")]),
      !anytrue([for r in kubernetes_cluster_role_v1.this[0].rule : contains(r.resources, "secrets") || contains(r.resources, "configmaps")]),
      alltrue([for r in kubernetes_cluster_role_v1.this[0].rule : length(setsubtract(r.verbs, ["get", "list", "watch"])) == 0]),
    ])
    error_message = "the cluster role should be read-only, without logs, secrets, or configmaps"
  }
}

run "cluster_reader_with_logs" {
  module {
    source = "./modules/cluster-reader"
  }

  variables {
    cluster_name     = "dev-use1"
    lambda_role_arn  = "arn:aws:iam::111122223333:role/eg-ue1-ops-argocd-slack"
    read_logs        = true
    role_name        = "argocd-slack-dev-use1"
    kubernetes_group = "argocd-slack"
  }

  assert {
    condition = alltrue([
      aws_iam_role.this[0].name == "argocd-slack-dev-use1",
      anytrue([for r in kubernetes_cluster_role_v1.this[0].rule : contains(r.resources, "pods/log") && length(r.verbs) == 1 && contains(r.verbs, "get")]),
      kubernetes_cluster_role_v1.this[0].metadata[0].name == "argocd-slack",
      output.kubernetes_group == "argocd-slack",
    ])
    error_message = "read_logs should add pod logs, and the names should follow the inputs"
  }
}
