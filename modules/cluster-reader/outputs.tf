output "role_arn" {
  description = "ARN of the reader role; list it in the root module's `cluster_role_arns` and the cluster's `role_arn`"
  value       = try(aws_iam_role.this[0].arn, null)
}

output "role_name" {
  description = "Name of the reader role"
  value       = try(aws_iam_role.this[0].name, null)
}

output "kubernetes_group" {
  description = "Kubernetes group bound to the read-only ClusterRole"
  value       = var.kubernetes_group
}
