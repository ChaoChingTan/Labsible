# Guacamole Kali Lab on AWS

Browser-based Kali Linux labs on AWS: Apache Guacamole behind an ALB connects to per-student Kali desktops over RDP. This README is updated as each part is built.

- **Region:** ap-southeast-1
- **IaC:** CloudFormation

## Status

| Component | State |
|---|---|
| `cfn/01-network.yaml` | Written, passes `cfn-lint`. Not yet deployed. |

## Repo layout

```
cfn/
  01-network.yaml    VPC, subnets, routing, security groups
README.md
```

---

## 01-network.yaml

Permanent stack. Creates the VPC and everything the later stacks attach to.

### Design decisions

- **New VPC (`10.0.0.0/16`)**, not the default VPC. The default VPC's `/20` subnets overlap `172.31.31.0/24` and `172.31.32.0/24`, so the class ranges cannot be created there.
- **No NAT Gateway.** All subnets are public and route `0.0.0.0/0` to the Internet Gateway. Instances get a public IPv4 for outbound access (set at launch by the stacks that create them).
- **Security groups are the inbound control**, because instances have public IPs. The client SG allows only RDP from the Guacamole SG.

### Resources

| Resource | Detail |
|---|---|
| VPC | `10.0.0.0/16`, DNS support and hostnames enabled |
| Internet Gateway | Attached to the VPC |
| Route table | One shared public table, default route to the IGW, associated with every subnet |
| S3 gateway endpoint | On the public route table; keeps S3 traffic off the public path |

### Subnets

Each subnet is the `/24` whose third octet matches the index below, carved with `Fn::Cidr`. All have `MapPublicIpOnLaunch` on.

| Subnet | CIDR | AZ | Purpose |
|---|---|---|---|
| `lab-alb-a` | `10.0.1.0/24` | AZ A | ALB |
| `lab-alb-b` | `10.0.2.0/24` | AZ B | ALB (second AZ required) |
| `lab-guac` | `10.0.10.0/24` | AZ A | Guacamole host |
| `lab-class-PA31` | `10.0.31.0/24` | AZ A | Class PA31 Kali clients |
| `lab-class-PA32` | `10.0.32.0/24` | AZ A | Class PA32 Kali clients |
| `lab-class-PA33` | `10.0.33.0/24` | AZ A | Class PA33 Kali clients |

Guacamole and class subnets share AZ A to avoid cross-AZ traffic charges.

Planned student address convention within a class subnet: `10.0.<class>.<100 + index>` (index 1 → `.101`, index 7 → `.107`).

### Security groups

| SG | Inbound |
|---|---|
| `lab-alb-sg` | 443 and 80 from `0.0.0.0/0` |
| `lab-guac-sg` | 8080 from `lab-alb-sg` |
| `lab-client-sg` | 3389 from `lab-guac-sg` only. No SSH, no CIDR rules. |

### Parameters

| Parameter | Default | Notes |
|---|---|---|
| `LabPrefix` | `lab` | Prefix for names and export names |
| `VpcCidr` | `10.0.0.0/16` | Must be a `/16` |
| `Class1` / `Class2` / `Class3` | `31` / `32` / `33` | Third octet of each class subnet (PA31, PA32, PA33) |

### Exports

All prefixed with `LabPrefix` (default `lab`):

`lab-VpcId`, `lab-VpcCidr`, `lab-AlbSubnetIds` (comma-separated), `lab-GuacSubnetId`, `lab-ClassSubnet-PA31`, `lab-ClassSubnet-PA32`, `lab-ClassSubnet-PA33`, `lab-AlbSgId`, `lab-GuacSgId`, `lab-ClientSgId`

### Deploy

```bash
aws cloudformation deploy \
  --region ap-southeast-1 \
  --stack-name lab-network \
  --template-file cfn/01-network.yaml

aws cloudformation update-termination-protection \
  --region ap-southeast-1 \
  --stack-name lab-network \
  --enable-termination-protection
```

### Lint

```bash
pip install cfn-lint
cfn-lint cfn/01-network.yaml
```

### Verify after deploy

1. `aws cloudformation describe-stacks --stack-name lab-network --query 'Stacks[0].Outputs'` lists all exports.
2. Launch a test instance in the PA31 subnet with a public IP and `lab-client-sg`. Confirm it can reach the internet.
3. Confirm 3389 is not reachable from outside the Guacamole SG.
4. Delete the test instance.