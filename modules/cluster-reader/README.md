# cluster-reader

Gives [argocd-slack-app](https://github.com/cruxstack/argocd-slack-app) read-only
access to one EKS cluster: an IAM role only the function's role can assume, an
EKS access entry that maps it to a Kubernetes group, and a ClusterRole bound to
that group.

The ClusterRole can get, list, and watch Argo CD Applications, and get and list
pods, events, Deployments, ReplicaSets, StatefulSets, DaemonSets, Jobs,
HorizontalPodAutoscalers, and Argo Rollouts. With `read_logs = true` it can also
read pod logs, so the app can show the last error line of a crashed container.
It can't read Secrets or ConfigMaps or change anything.

The cluster must use the `API` or `API_AND_CONFIG_MAP` authentication mode for
access entries.

## Usage

Apply it with the cluster account's AWS provider and a Kubernetes provider for
the cluster, after the root module has created the function's role:

```hcl
module "cluster_reader" {
  source = "github.com/cruxstack/terraform-aws-argocd-slack-app//modules/cluster-reader?ref=v0.1.0"

  cluster_name    = "prod-use1"
  lambda_role_arn = "arn:aws:iam::111122223333:role/eg-ue1-ops-argocd-slack"
  read_logs       = false
}
```

Then list `module.cluster_reader.role_arn` in the root module's
`cluster_role_arns` and as the cluster's `role_arn` in `app_config.clusters`.

## Inputs

| Name               | Description                                                      | Type     | Default                         | Required |
| ------------------ | ---------------------------------------------------------------- | -------- | ------------------------------- | -------- |
| `cluster_name`     | name of the EKS cluster                                          | `string` | n/a                             | yes      |
| `lambda_role_arn`  | ARN of the function's role (the root module's `role_arn` output) | `string` | n/a                             | yes      |
| `read_logs`        | let the function read pod logs                                   | `bool`   | `false`                         | no       |
| `role_name`        | name of the reader role                                          | `string` | `"<cluster_name>-argocd-slack"` | no       |
| `kubernetes_group` | group of the access entry; also the ClusterRole's name           | `string` | `"argocd-slack-reader"`         | no       |

The `cloudposse/label/null` variables (`enabled`, `tags`, and so on) are
available too.

## Outputs

| Name               | Description                                  |
| ------------------ | -------------------------------------------- |
| `role_arn`         | ARN of the reader role                       |
| `role_name`        | name of the reader role                      |
| `kubernetes_group` | Kubernetes group bound to the read-only role |
