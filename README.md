# AWS Infrastructure Endpoints & Network Reference (Fara Inc)

Production deployment: **us-east-1**, account `528893196824`, domain `e2b.landing.money`.

## Public Endpoints

| Endpoint | URL | Purpose |
|----------|-----|---------|
| API (REST + gRPC) | `https://api.e2b.landing.money` | Main E2B API — health check: `/health` |
| Nomad UI | `https://nomad.e2b.landing.money` | Cluster management UI (requires ACL token, see below) |
| Sandbox access | `https://<sandbox-id>.e2b.landing.money` | Per-sandbox URLs via client-proxy |
| Wildcard DNS | `*.e2b.landing.money` | Cloudflare CNAME → ALB (not proxied, TTL 3600) |

### Nomad UI Access Token

The Nomad UI requires an ACL token. Retrieve it from AWS Secrets Manager:

```sh
aws secretsmanager get-secret-value --secret-id e2b-cluster \
  --region us-east-1 --query SecretString --output text \
  | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['NOMAD_ACL_TOKEN'])"
```

Paste the token into the Nomad UI's ACL Token prompt (lock icon, top-right corner).

## ALB Routing (port 443, TLS terminated)

| Priority | Condition | Target Group | Backend Port |
|----------|-----------|-------------|-------------|
| 10 | Host: `nomad.e2b.landing.money` | `e2b-nomad` | 4646 (Nomad) |
| 20 | Header: `content-type: application/grpc*` | `e2b-ingress-grpc` (HTTP/2) | 8080 (Traefik) |
| default | All other requests | `e2b-ingress` (HTTP/1.1) | 8080 (Traefik) |

Port 80 redirects to 443 (HTTP 301). ACM wildcard cert: `*.e2b.landing.money`.

## Traefik Ingress Routing (port 8080)

| Service | Priority | Route Rule |
|---------|----------|------------|
| dashboard-api | 1000 | `HostRegexp(<subdomain>.{domain:.+})` |
| api | 500 | `HostRegexp(api.{domain:.+})` |
| client-proxy | 100 | `PathPrefix(/)` (catch-all) |

## Internal Service Ports

| Service | Port | Protocol | Notes |
|---------|------|----------|-------|
| API HTTP | 80 | HTTP | Behind Traefik |
| API gRPC | 5009 | gRPC | `api-grpc` Consul service |
| Orchestrator gRPC | 5008 | gRPC | System job on client nodes |
| Orchestrator proxy | 5007 | TCP | System job on client nodes |
| Template manager | 5008 | gRPC | On build nodes |
| Client proxy | 3002 | HTTP | Sandbox traffic |
| Client proxy health | 3001 | HTTP | Health check |
| Redis | 6379 | TCP | `redis.service.consul` |
| ClickHouse (native) | 9000 | TCP | `clickhouse.service.consul` |
| ClickHouse HTTP | 8123 | HTTP | Internal health check |
| Loki | 3100 | HTTP | `loki.service.consul` |
| OTel Collector gRPC | 4317 | gRPC | System job on all nodes |
| OTel Collector HTTP | 4318 | HTTP | System job on all nodes |
| Consul | 8500 | HTTP | Internal only |
| Nomad | 4646 | HTTP | Exposed via ALB |

## VPC Network Layout (`10.0.0.0/16`)

| Subnet | CIDRs | Purpose |
|--------|-------|---------|
| Public | `10.0.1.0/24` – `10.0.3.0/24` | ALB (us-east-1a/b/c) |
| Private | `10.0.11.0/24` – `10.0.16.0/24` | All EC2 nodes (6 subnets) |
| ElastiCache | `10.0.21.0/24` – `10.0.23.0/24` | Redis (if managed) |

VPC Endpoints: S3 (Gateway), Secrets Manager, EC2, EC2 Instance Connect (all private subnets). Single shared NAT Gateway.

## AWS Secrets Manager

| Secret ID | Content |
|-----------|---------|
| `e2b-cloudflare` | `{"TOKEN": "..."}` |
| `e2b-postgres-connection-string` | Supabase Session Pooler URL |
| `e2b-supabase-jwt-secrets` | JWT secret |
| `e2b-cluster` | Nomad/Consul ACL tokens + gossip key |
| `e2b-clickhouse` | Username, password, server secret |
| `e2b-grafana` | Grafana API key, OTLP URLs, collector tokens |
| `e2b-api-secret` | API internal secret |
| `e2b-admin-token` | Admin API token |
| `e2b-sandbox-access-token-hash-seed` | Sandbox access token seed |
| `e2b-launch-darkly-api-key` | Feature flags (empty = disabled) |
| `e2b-redis-cluster-url` | Redis TLS URL (if managed) |
| `e2b-redis-tls-ca-base64` | Redis TLS CA cert (if managed) |

## Security Groups

| Group | Inbound Rules |
|-------|--------------|
| `e2b-ingress-load-balancer` | TCP 80, 443 from `0.0.0.0/0` |
| `e2b-cluster-node` | TCP 22 from Instance Connect SG; TCP 4646, 8080 from ALB SG; all traffic self (cluster) |

---

# AWS Self-Hosting Deployment Guide (Fara Inc)

Practical deployment guide for self-hosting E2B on AWS, based on our production deployment to `us-east-1`. This documents the actual steps, gotchas, and fixes discovered during deployment.

## Architecture

```
Internet
  |
Cloudflare DNS (*.e2b.landing.money -> ALB)
  |
AWS ALB (public subnets, ACM wildcard cert)
  |-- Host: nomad.*        --> Control Servers (Nomad UI, port 4646)
  |-- Content-Type: grpc   --> API nodes (Traefik, port 8080)
  |-- Default              --> API nodes (Traefik, port 8080)
                                |
                  Traefik Ingress (priority routing)
                    |           |           |
                  API(P:500) Client-Proxy Dashboard-API
                    |        (P:100)      (P:1000)
                    |
              Orchestrator Nodes (m8i.16xlarge)
                |-- Firecracker VMs (raw_exec)
                |-- s3fs -> S3 (kernels, envd, fc-versions)
                |-- Hugepages (60% reserved)
                |-- 100GB swap, 65GB tmpfs snapshot cache
```

## EC2 Node Pools

| Pool | Instance Type | Count | Purpose |
|------|-------------|-------|---------|
| Control Server | `t3.medium` | 3 | Nomad/Consul servers (HA) |
| API | `t3.xlarge` | 1 | API, Traefik ingress, client-proxy, Loki, OTel |
| Client (Orchestrator) | `m8i.16xlarge` | 1 | Firecracker microVMs (~63-88 concurrent sandboxes) |
| Build | `m8i.2xlarge` | 1 | Template manager (sandbox image builder) |
| ClickHouse | `t3.xlarge` | 1 | Analytics DB with persistent EBS |

Estimated monthly cost: ~$3,300/mo (on-demand, us-east-1).

## Prerequisites

- AWS CLI configured (`aws configure --profile default`)
- Terraform >= 1.0
- Packer >= 1.8.4
- Docker, Go, Node.js/npm
- Cloudflare account with domain (`landing.money`)
- Supabase project (PostgreSQL + JWT auth)

## Step-by-Step Deployment

### 1. Create environment file

```sh
cp .env.aws.template .env.prod
```

Fill in `.env.prod`:
```
AWS_PROFILE=default
AWS_ACCOUNT_ID=<your-account-id>
AWS_REGION=us-east-1
DOMAIN_NAME=e2b.landing.money
PROVIDER=aws
PREFIX=e2b-
TERRAFORM_ENVIRONMENT=prod
CLIENT_SERVER_MACHINE_TYPE=m8i.16xlarge
```

### 2. Set environment and authenticate

```sh
make set-env ENV=prod
make provider-login
```

### 3. Build AMI (skip if already built)

```sh
cd iac/provider-aws/nomad-cluster-disk-image
make init
make build    # ~15 min, creates Ubuntu 22.04 AMI with Consul/Nomad/Docker/s3fs
```

### 4. Bootstrap infrastructure

```sh
make init     # Creates VPC, ECR repos, S3 buckets, Secrets Manager entries
```

### 5. Populate secrets in AWS Secrets Manager

```sh
# Cloudflare API token (Edit Zone DNS permission for your domain)
aws secretsmanager put-secret-value \
  --secret-id e2b-cloudflare \
  --secret-string '{"TOKEN": "your-cloudflare-token"}' \
  --region us-east-1

# PostgreSQL connection string (use Supabase Session Pooler URL!)
aws secretsmanager put-secret-value \
  --secret-id e2b-postgres-connection-string \
  --secret-string 'postgresql://postgres.<project-ref>:<password>@<region>.pooler.supabase.com:5432/postgres' \
  --region us-east-1

# Supabase JWT secret
aws secretsmanager put-secret-value \
  --secret-id e2b-supabase-jwt-secrets \
  --secret-string 'your-jwt-secret' \
  --region us-east-1
```

### 6. Build and upload artifacts

```sh
make copy-public-builds    # Copies Firecracker kernels from E2B public GCS bucket to your S3
make build-and-upload      # Builds Docker images -> ECR, Go binaries -> S3
```

### 7. Deploy infrastructure (without Nomad jobs)

```sh
make plan-without-jobs && make apply
```

> **KNOWN ISSUE:** `plan-without-jobs` only targets Terraform modules, skipping root-level
> resources (ALB, ACM cert, Cloudflare DNS in `alb.tf`/`domain.tf`). Run this targeted apply
> to create them:

```sh
cd iac/provider-aws && \
source ../../.env.prod && \
AWS_PROFILE=$AWS_PROFILE AWS_REGION=$AWS_REGION \
  TF_VAR_environment=$TERRAFORM_ENVIRONMENT \
  TF_VAR_prefix=$PREFIX \
  TF_VAR_domain_name=$DOMAIN_NAME \
  TF_VAR_bucket_prefix=${PREFIX}${AWS_ACCOUNT_ID}- \
  TF_VAR_aws_account_id=$AWS_ACCOUNT_ID \
  TF_VAR_aws_region=$AWS_REGION \
  TF_VAR_client_server_machine_type=m8i.16xlarge \
  terraform apply \
    -target=aws_lb.ingress \
    -target=aws_acm_certificate.wildcard \
    -target=aws_acm_certificate_validation.wildcard \
    -target=cloudflare_record.cert \
    -target=cloudflare_record.routing \
    -target=aws_lb_listener.http \
    -target=aws_lb_listener.https \
    -target=aws_lb_listener_rule.nomad \
    -target=aws_lb_listener_rule.grpc \
    -input=false -compact-warnings
```

### 8. Deploy Nomad jobs

```sh
make plan && make apply
```

### 9. Fix orchestrator node metadata

> **KNOWN ISSUE:** AWS `run-nomad.sh` doesn't set `orchestrator_job_version` in node metadata,
> but the orchestrator job requires it as a placement constraint. Without this, the orchestrator
> won't schedule and the API health check will fail.

```sh
# Get the orchestrator job hash from Nomad
NOMAD_TOKEN=$(aws secretsmanager get-secret-value --secret-id e2b-cluster \
  --region us-east-1 --query SecretString --output text \
  | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['NOMAD_ACL_TOKEN'])")

ORCH_HASH=$(curl -s -H "X-Nomad-Token: $NOMAD_TOKEN" \
  "https://nomad.<your-domain>/v1/jobs?prefix=orchestrator" \
  | python3 -c "
import sys, json
for j in json.loads(sys.stdin.read()):
    if j['Status'] == 'running':
        print(j['Name'].split('-', 1)[1]); break
")

# Get the client node instance ID
INSTANCE_ID=$(aws ec2 describe-instances --region us-east-1 \
  --filters "Name=tag:Name,Values=*orch-client*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

# SSH in and apply the metadata
TMPKEY=$(mktemp -u /tmp/e2b-ssh-XXXX)
ssh-keygen -t ed25519 -f "$TMPKEY" -N "" -q

AZ=$(aws ec2 describe-instances --region us-east-1 --instance-ids $INSTANCE_ID \
  --query 'Reservations[].Instances[].Placement.AvailabilityZone' --output text)

aws ec2-instance-connect send-ssh-public-key \
  --instance-id $INSTANCE_ID \
  --instance-os-user ubuntu \
  --ssh-public-key "file://${TMPKEY}.pub" \
  --region us-east-1 \
  --availability-zone $AZ

ssh -i "$TMPKEY" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=10 \
  -o ProxyCommand="aws ec2-instance-connect open-tunnel --instance-id $INSTANCE_ID --region us-east-1" \
  ubuntu@$INSTANCE_ID \
  "sudo NOMAD_TOKEN=$NOMAD_TOKEN nomad node meta apply orchestrator_job_version=$ORCH_HASH"

rm -f "$TMPKEY" "${TMPKEY}.pub"
```

Verify the orchestrator starts and API becomes healthy:
```sh
curl https://api.<your-domain>/health
# Expected: "Health check successful"
```

### 10. Seed database and build base template

```sh
cd packages/shared && \
POSTGRES_CONNECTION_STRING='postgresql://postgres.<ref>:<pass>@<region>.pooler.supabase.com:5432/postgres' \
make prep-cluster
```

This prompts for email, creates initial user/team, and builds the base sandbox template. Save the printed **Access Token** and **Team API Key**.

If `prep-cluster` fails on the template build (e.g., stale `E2B_API_KEY` in env), run the build step separately with the new key:

```sh
cd packages/shared && \
E2B_API_KEY=<team-api-key-from-seed-output> \
make build-base-template
```

### 11. Test with SDK

```javascript
import { Sandbox } from "e2b";

const sandbox = await Sandbox.create({
  domain: "e2b.landing.money",
});
console.log("Sandbox created:", sandbox.sandboxId);
await sandbox.close();
```

## Known Issues & Gotchas

### 1. ALB/DNS not created by `plan-without-jobs`

**Cause:** `alb.tf` and `domain.tf` are root-level Terraform resources, but `plan-without-jobs` only targets `module.*` blocks.
**Fix:** Targeted apply for root resources (see Step 7 above).

### 2. Orchestrator not scheduling (no allocations)

**Cause:** AWS `run-nomad.sh` doesn't set `orchestrator_job_version` node metadata, but the orchestrator job has a constraint on it. GCP's version does this correctly.
**Fix:** Manually apply node metadata via SSH (see Step 9 above). Must be re-applied after each `make plan && make apply` that changes the orchestrator binary.

### 3. Supabase connection: use Session Pooler, not Direct Connection

**Cause:** Direct connection (`db.<ref>.supabase.co:5432`) fails with TLS EOF errors.
**Fix:** Use the **Session Pooler** URL from Supabase dashboard: `postgresql://postgres.<ref>:<pass>@<region>.pooler.supabase.com:5432/postgres`

### 4. DB seed must run AFTER migrations

**Cause:** `make prep-cluster` runs the seed which needs tables created by the db-migrator Nomad task.
**Fix:** Ensure `make plan && make apply` completes (which runs db-migrator) before running `make prep-cluster`.

### 5. `E2B_API_KEY` env var may be stale

**Cause:** Each seed run generates new API keys. If `E2B_API_KEY` is set in the environment from a previous run, the build step uses the old (non-existent) key.
**Fix:** Explicitly pass the new key: `E2B_API_KEY=<new-key> make build-base-template`

### 6. LaunchDarkly 401 warnings

**Cause:** The `e2b-launch-darkly-api-key` secret is empty.
**Impact:** Non-blocking warning. Feature flags fall back to defaults. Can be ignored for self-hosting.

## Capacity: m8i.16xlarge (64 vCPU, 256 GB RAM)

For Claude Code CLI + Rails dev workloads (4 vCPU, 4 GB RAM per sandbox):

| Scenario | Concurrent Sandboxes |
|----------|---------------------|
| All peak simultaneously | ~63 |
| Normal dev (mixed usage) | ~70-80 |
| Mostly idle (coding) | ~80-88 |

Scale by adding more client nodes: `CLIENT_CLUSTER_SIZE=2` in `.env.prod`.

---

![E2B Infra Preview Light](/readme-assets/infra-light.png#gh-light-mode-only)
![E2B Infra Preview Dark](/readme-assets/infra-dark.png#gh-dark-mode-only)

# E2B Infrastructure

[E2B](https://e2b.dev) is an open-source infrastructure for AI code interpreting. In our main repository [e2b-dev/e2b](https://github.com/e2b-dev/E2B) we are giving you SDKs and CLI to customize and manage environments and run your AI agents in the cloud.

This repository contains the infrastructure that powers the E2B platform.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for ways you can contribute to E2B Infrastructure.

## Self-hosting

Read the [self-hosting guide](./self-host.md) to learn how to set up the infrastructure on your own. The infrastructure is deployed using Terraform.

Supported cloud providers:
- 🟢 GCP
- 🟢 AWS (Beta)
- [ ] Azure
- [ ] General linux machine
