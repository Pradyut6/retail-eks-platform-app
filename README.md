# Retail EKS Platform

**A five-service storefront on Amazon EKS, with private ingress, managed AWS data services, and container builds that leave the build toolchain behind.**

[![EKS and security checks](https://github.com/Pradyut6/retail-eks-platform-app/actions/workflows/eks-checks.yml/badge.svg?branch=main)](https://github.com/Pradyut6/retail-eks-platform-app/actions/workflows/eks-checks.yml)
[![End-to-end tests](https://github.com/Pradyut6/retail-eks-platform-app/actions/workflows/e2e-test.yml/badge.svg?branch=main)](https://github.com/Pradyut6/retail-eks-platform-app/actions/workflows/e2e-test.yml)

[Architecture](#aws-architecture) · [Traffic](#microservice-traffic) · [Image builds](#multi-stage-al2023-images) · [CI](#verification-and-deployment-workflow) · [Helm and availability](#before-and-after-helm)

## AWS architecture

The default EKS profile runs each service in its own namespace and connects the application to managed AWS dependencies. In the default non-Istio path, an **internal Network Load Balancer** forwards storefront traffic to UI Pods. Operators reach the Kubernetes API through a separate private endpoint path.

```mermaid
flowchart LR
    Shopper["Browser on a connected network"]
    Operator["Operator or Terraform runner"]
    Logs["CloudWatch · 30-day control-plane logs"]
    subgraph VPC["AWS VPC"]
        direction LR
        NLB["Internal Network Load Balancer"]
        API["Private EKS API endpoint"]
        subgraph EKS["Amazon EKS workloads"]
            direction TB
            UI["UI"]
            Catalog["Catalog"]
            Cart["Cart"]
            Checkout["Checkout"]
            Orders["Orders"]
            UI --> Catalog & Cart & Checkout & Orders
            Checkout --> Orders
        end
        subgraph Data["Managed AWS dependencies"]
            direction TB
            MySQL[("Aurora MySQL")]
            Search[("OpenSearch")]
            DDB[("DynamoDB")]
            Cache[("ElastiCache")]
            Postgres[("Aurora PostgreSQL")]
            MQ["Amazon MQ · RabbitMQ"]
        end
        NLB --> UI
        Catalog --> MySQL & Search
        Cart --> DDB
        Checkout --> Cache
        Orders --> Postgres & MQ
    end
    Shopper --> NLB
    Operator -. Kubernetes API .-> API
    API --> Logs
    classDef entry fill:#dbeafe,stroke:#2563eb,color:#172554
    classDef workload fill:#dcfce7,stroke:#15803d,color:#052e16
    classDef data fill:#fef3c7,stroke:#b45309,color:#451a03
    class Shopper,Operator,NLB,API,Logs entry
    class UI,Catalog,Cart,Checkout,Orders workload
    class MySQL,Search,DDB,Cache,Postgres,MQ data
```

| Service | Runtime | Responsibility | Default EKS dependency |
| --- | --- | --- | --- |
| **UI** · `ui` | Java 21 | Storefront and server-side API calls | Catalog, Cart, Checkout, and Orders |
| **Catalog** · `catalog` | Go | Product details and search | Aurora MySQL and OpenSearch |
| **Cart** · `carts` | Java 21 | Cart reads and writes | DynamoDB via IAM role for service accounts |
| **Checkout** · `checkout` | Node.js 20 | Checkout state and order submission | ElastiCache and Orders API |
| **Orders** · `orders` | Java 21 | Order writes, reads, and messaging | Aurora PostgreSQL and Amazon MQ for RabbitMQ |

[Terraform Helm wiring](terraform/eks/default/kubernetes.tf) · [Managed service definitions](terraform/lib/dependencies)

## Microservice traffic

The browser talks to the storefront. The storefront calls the backend Services over cluster DNS, and Checkout calls Orders when an order is submitted.

```mermaid
sequenceDiagram
    autonumber
    actor Browser
    participant UI as NLB → UI Service → UI Pod
    participant Catalog as Catalog API
    participant Cart as Cart API
    participant Checkout as Checkout API
    participant Orders as Orders API
    participant Data as AWS data services

    Browser->>UI: Browse products or search
    UI->>Catalog: Query catalog
    Catalog->>Data: Read Aurora MySQL or query OpenSearch
    Catalog-->>UI: Product results
    UI-->>Browser: Render storefront

    Browser->>UI: Add item to cart
    UI->>Cart: Update cart
    Cart->>Data: Write cart to DynamoDB
    Cart-->>UI: Updated cart

    Browser->>UI: Submit checkout
    UI->>Checkout: Submit checkout details
    Checkout->>Data: Access checkout state in ElastiCache
    Checkout->>Orders: Create order
    Orders->>Data: Persist order in Aurora PostgreSQL
    Orders->>Data: Publish order event to RabbitMQ
    Orders-->>Checkout: Order response
    Checkout-->>UI: Checkout result
    UI-->>Browser: Show confirmation
```

The diagram shows the application call path. [Storefront service endpoints](terraform/eks/default/values/ui.yaml) · [Checkout order submission](src/checkout/src/checkout/checkout.service.ts)

## Multi-stage AL2023 images

Each application Dockerfile builds an artifact in one stage and copies only the runtime deliverables into a fresh Amazon Linux 2023 stage. UI, Cart, Orders, and Catalog use AL2023 builders. Checkout uses Node 20 Alpine to build TypeScript and prune development dependencies, then runs on AL2023 with Node.js 20.

```mermaid
flowchart LR
    Source["Service source and locked dependencies"]
    subgraph Before["Build stage"]
        J["AL2023 · Maven and Java"]
        G["AL2023 · Go compiler"]
        N["Node 20 Alpine · Yarn and TypeScript"]
        Tools["Build tooling, sources and build caches"]
        J & G & N -. remain in builder .-> Tools
    end
    subgraph After["Fresh AL2023 runtime stage"]
        RJ["Corretto 21 headless and app.jar"]
        RG["Catalog executable and runtime packages"]
        RN["Node.js 20, dist and production node_modules"]
        User["Non-root application user"]
        RJ & RG & RN --> User
    end
    Source --> J & G & N
    J -->|COPY from builder: JAR| RJ
    G -->|COPY from builder: executable| RG
    N -->|COPY from builder: app and production dependencies| RN
    User --> Image["Runtime image for Kubernetes"]
    classDef build fill:#fef3c7,stroke:#b45309,color:#451a03
    classDef runtime fill:#dcfce7,stroke:#15803d,color:#052e16
    class J,G,N,Tools build
    class RJ,RG,RN,User,Image runtime
```

| Image family | Builder does | Final image receives |
| --- | --- | --- |
| [UI](src/ui/Dockerfile), [Cart](src/cart/Dockerfile), [Orders](src/orders/Dockerfile) | Resolves Maven dependencies and packages the application | Application JAR and Corretto headless runtime |
| [Catalog](src/catalog/Dockerfile) | Resolves Go modules and compiles the server | Compiled server and runtime packages |
| [Checkout](src/checkout/Dockerfile) | Builds TypeScript and prunes development dependencies | Compiled JavaScript, production dependencies, and Node.js |

The runtimes apply AL2023 package updates, skip weak package dependencies, and run the application as a non-root user. [AL2023 release updates](https://docs.aws.amazon.com/linux/al2023/ug/deterministic-upgrades-usage.html)

## Verification and deployment workflow

```mermaid
flowchart TB
    Change["Push or pull request"]
    subgraph CI["GitHub Actions"]
        PR["PR checks · lint, project tasks and container builds"]
        TF["EKS checks · Terraform init and validation"]
        Scan["Trivy · vulnerabilities and secrets"]
        Compose["Docker Compose E2E · single, multi-service and search"]
        Kind["Kind E2E · build, load and deploy images"]
    end
    Change --> PR & TF & Scan & Compose & Kind
    PR & TF & Scan & Compose & Kind --> Review["Review verification results"]
    Review -. operator reviews plan .-> Plan["Terraform plan for the target AWS account"]
    Plan --> Apply["Operator applies selected EKS profile"]
    Apply --> Helm["Default profile applies the service charts"]
    Helm --> Verify["Check rollouts, Services and internal ingress"]
    classDef verify fill:#e0f2fe,stroke:#0369a1,color:#082f49
    classDef deploy fill:#dcfce7,stroke:#15803d,color:#052e16
    class PR,TF,Scan,Compose,Kind,Review verify
    class Plan,Apply,Helm,Verify deploy
```

GitHub Actions verifies the repository without AWS deployment credentials. An operator separately reviews and applies the AWS Terraform plan. The **minimal** profile provisions the cluster and network. The **default** profile also provisions the application dependencies and installs the Helm releases. The UI release depends on the four backend releases.

[PR workflow](.github/workflows/pr.yaml) · [EKS and security workflow](.github/workflows/eks-checks.yml) · [E2E workflow](.github/workflows/e2e-test.yml)

## Before and after Helm

```mermaid
flowchart LR
    subgraph Before["Before applying the service charts"]
        Images["Resolved image repositories and tags"]
        Inputs["Chart templates and Terraform-rendered values"]
        Cluster["EKS nodes and service namespaces"]
    end
    Images & Inputs & Cluster --> Helm["Terraform Helm releases"]
    subgraph After["After applying the service charts"]
        Deployment["Deployment"]
        Pods["Application Pods"]
        Service["Service → ready Pods"]
        HPA["Optional HPA"]
        Metrics["Resource metrics API"]
        PDB["Optional PDB"]
        Eviction["Voluntary eviction request"]
        Deployment --> Pods
        Service --> Pods
        Metrics --> HPA
        HPA -->|scales| Deployment
        Eviction --> PDB
        PDB -. checks availability .-> Pods
    end
    Helm --> Deployment & Service
    Helm -. when enabled .-> HPA & PDB
    classDef optional fill:#fef3c7,stroke:#b45309,color:#451a03
    class HPA,Metrics,PDB,Eviction optional
```

**HPA and PDB resources are opt-in.** The standard Terraform-supplied values leave both disabled. With HPA enabled, a working resource metrics API and CPU requests let Kubernetes adjust Deployment replicas. With PDB enabled, Kubernetes checks availability before allowing voluntary evictions such as node drains. A PDB cannot prevent an involuntary outage.

For a chart-level preview of an HA configuration, create this values file and render the UI chart from the repository root. When Terraform owns a release, incorporate approved changes in its Helm values to keep the deployment reproducible.

```yaml
# availability.yaml
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 60
podDisruptionBudget:
  enabled: true
  minAvailable: 1
  maxUnavailable: null
```

```sh
helm template ui src/ui/chart --namespace ui -f availability.yaml
```

Use one disruption budget field. Here, `null` removes the chart’s default `maxUnavailable` value so that only `minAvailable` is emitted. [UI HPA template](src/ui/chart/templates/hpa.yaml) · [UI PDB template](src/ui/chart/templates/pdb.yaml)

## Run and verify

**Local preview.** The standalone upstream image starts the sample storefront without provisioning AWS infrastructure.

```sh
docker run --rm -p 127.0.0.1:8888:8080 public.ecr.aws/aws-containers/retail-store-sample-ui:1.0.0
```

Open [localhost:8888](http://localhost:8888). Use the [developer guide](DEVELOPER_GUIDE.md) for source builds and multi-service testing.

**EKS.** Start with the [minimal](terraform/eks/minimal/README.md) or [default](terraform/eks/default/README.md) profile. Run Terraform from a network that can reach the private EKS API. Review the plan and keep state in an access-controlled, encrypted backend. The default stack creates billable infrastructure.

After deploying the default profile without Istio, configure kubectl with the profile’s `configure_kubectl` output, then verify the storefront:

```sh
kubectl get nodes
kubectl -n ui rollout status deployment/ui --timeout=180s
kubectl -n ui get svc ui
kubectl -n ui get endpointslices -l kubernetes.io/service-name=ui
kubectl -n ui port-forward svc/ui 8080:80
```

| Signal | Start here |
| --- | --- |
| Terraform or kubectl cannot reach the API | Check private DNS and routing from the runner or operator network. |
| Internal NLB is pending | Check UI Service events and AWS Load Balancer Controller logs. |
| Storefront loads but an action fails | Check the UI logs, the affected backend, and its managed dependency. |
| HPA reports unknown CPU | Check the resource metrics API and container CPU requests. |
| A node drain stalls | Review the PDB’s allowed disruptions and ready replica count. |

Both EKS profiles export all five control-plane log categories to CloudWatch with 30 days of retention. For endpoint access, rollout verification, and teardown, use the [EKS operations runbook](docs/eks-operations.md).

## Attribution

Based on the [AWS Containers Retail Sample](https://github.com/aws-containers/retail-store-sample-app). The source and demo assets retain their original attribution under the [repository license](LICENSE).
