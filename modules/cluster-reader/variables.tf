variable "cluster_name" {
  description = "Name of the EKS cluster the function reads."
  type        = string
}

variable "lambda_role_arn" {
  description = "ARN of the argocd-slack-app function's role, the root module's `role_arn` output. Only it may assume the reader role."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/", var.lambda_role_arn))
    error_message = "lambda_role_arn must be an IAM role ARN."
  }
}

variable "read_logs" {
  description = "Let the function read pod logs, so it can show the last error line of a crashed container. Leave off where logs can hold secrets."
  type        = bool
  default     = false
}

variable "role_name" {
  description = "Name of the reader IAM role. Defaults to `<cluster_name>-argocd-slack`."
  type        = string
  default     = null
}

variable "kubernetes_group" {
  description = "Kubernetes group the access entry maps the role to, and the name of the ClusterRole and its binding."
  type        = string
  default     = "argocd-slack-reader"
}
