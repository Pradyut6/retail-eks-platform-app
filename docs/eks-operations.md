# EKS operations

## Verify after deployment

Run these commands with the AWS account, region, and AWS CLI profile used for deployment.

```sh
aws eks describe-cluster --name retail-store \
  --query 'cluster.{endpoint:resourcesVpcConfig,logging:logging.clusterLogging}'
kubectl get nodes
kubectl get pods -A
```

Confirm that private API access is enabled. If public access is enabled, check that the displayed CIDRs match the operator allowlist. Confirm that the `/aws/eks/retail-store/cluster` log group has a 30-day retention policy.

For the default profile without Istio, check `kubectl -n ui get svc ui -o yaml` and confirm the load balancer scheme is internal. Open the storefront over a connected network. Browse the catalog, add a product to the cart, and place a demo order.

## Diagnose

- **Kubernetes API times out.** Check runner routing, VPC DNS resolution, and the CIDR allowlist. If the API responds with an authentication error, check the caller with `aws sts get-caller-identity` and verify the expected kubeconfig context.
- **Storefront fails to load.** Check `kubectl -n ui get pods,svc,endpointslices` and `kubectl -n ui describe svc ui`. If the NLB hostname exists but is unreachable, verify network connectivity from the client to the VPC.
- **Checkout fails.** Inspect events and logs in the checkout and orders namespaces. Verify the dependent endpoints and security groups before retrying an order.

## Remove the demo

Use the Terraform state and runner that created the environment. For the minimal profile, remove any workload and its load balancers first. For either profile, review `terraform plan -destroy`, then run `terraform destroy`. Confirm in AWS that the EKS cluster, NAT gateways, load balancers, and managed data stores were removed. Export any data you need before teardown because the sample database configuration skips final snapshots.
