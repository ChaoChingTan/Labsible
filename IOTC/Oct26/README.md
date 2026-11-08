# Guacamole Kali Lab on AWS

Browser-based Kali Linux labs on AWS: Apache Guacamole behind an ALB connects to per-student Kali desktops over RDP. This README is updated as each part is built.

- **Region:** ap-southeast-1
- **IaC:** CloudFormation

## Status

| Component | State |
|---|---|
| `cfn/01-network.yaml` | Deployed as stack `lab-network` in ap-southeast-1. |
| `cfn/02-platform.yaml` | Deployed as stack `lab-platform` in ap-southeast-1. |
| `cfn/03-storage.yaml` | Deployed as stack `lab-storage`; notes published; read-only policy applied by `scripts/apply-notes-policy.sh`. Read-only behaviour on a Kali client not yet verified (needs `20-class`). |
| `ami/kali-firstboot.sh` | Written. Logic tested manually on a Kali instance. Not yet run through cloud-init. |

## Repo layout

```
cfn/
  01-network.yaml    VPC, subnets, routing, security groups
  02-platform.yaml   ALB, ACM cert, Route53 record, S3 dump bucket, secrets, IAM
  03-storage.yaml    EFS for read-only lecture notes, mount targets, notes admin role
ami/
  kali-firstboot.sh  user-data for Kali instances (password, compositor, hostname, notes mount)
scripts/
  apply-notes-policy.sh   applies the read-only EFS policy after 03-storage is deployed
params/
  lab.env.example    template for local, git-ignored deployment settings
.gitignore
README.md
```

## Local configuration (not committed)

Environment-specific values (domain name, hosted zone ID) have no defaults in the templates and are never committed. Keep them in a git-ignored file:

```bash
cp params/lab.env.example params/lab.env   # edit with your real values
source params/lab.env
```

`.gitignore` excludes `params/*` (except `*.example`), `.env` files, rosters, CSVs, database dumps and key files.

---

## 01-network.yaml

Permanent stack. Creates the VPC and everything the later stacks attach to. The subnets and security groups are laid out for the planned traffic path:

```
internet -> ALB -> web nodes -> (internal NLB) -> guacd nodes -> Kali
                       |
                       +-> database
```

### Design decisions

- **New VPC (`10.0.0.0/16`)**, not the default VPC. The default VPC's `/20` subnets overlap `172.31.31.0/24` and `172.31.32.0/24`, so the class ranges cannot be created there.
- **No NAT Gateway.** All subnets are public and route `0.0.0.0/0` to the Internet Gateway. Instances get a public IPv4 for outbound access (set at launch by the stacks that create them).
- **Security groups are the inbound control**, because instances have public IPs. Every rule references another security group, never a CIDR (except the ALB's public ports).
- **One AZ per class.** A subnet lives in exactly one AZ, so each class keeps one `/24` and a clean index-to-IP mapping. Classes are spread over different AZs so an AZ outage affects one class only.
- **guacd, its NLB and Kali for a class share that class's subnet**, so guacd-to-Kali RDP never crosses an AZ.
- **Never allow guacd (4822) from a class subnet CIDR.** guacd has no authentication, and students on Kali could use it as a pivot.

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
| `lab-alb-a` | `10.0.1.0/24` | AZ index 0 | ALB (also used for the DB subnet group) |
| `lab-alb-b` | `10.0.2.0/24` | AZ index 1 | ALB (second AZ required) |
| `lab-guac-a` | `10.0.10.0/24` | AZ index 0 | Guacamole web nodes |
| `lab-guac-b` | `10.0.11.0/24` | AZ index 1 | Guacamole web nodes (second AZ) |
| `lab-class-PA31` | `10.0.31.0/24` | `Class1Az` (default 0) | PA31 guacd NLB, guacd nodes, Kali |
| `lab-class-PA32` | `10.0.32.0/24` | `Class2Az` (default 1) | PA32 guacd NLB, guacd nodes, Kali |
| `lab-class-PA33` | `10.0.33.0/24` | `Class3Az` (default 2) | PA33 guacd NLB, guacd nodes, Kali |

Planned address convention inside a class subnet: `10.0.<class>.<100 + index>` for students (index 1 → `.101`), and `.10` reserved for the class's guacd NLB.

### Security groups

| SG | Inbound | Used by |
|---|---|---|
| `lab-alb-sg` | 443 and 80 from `0.0.0.0/0` | ALB |
| `lab-guac-sg` | 8080 from `lab-alb-sg` | Guacamole web nodes |
| `lab-guacd-nlb-sg` | 4822 from `lab-guac-sg` | Per-class internal NLBs |
| `lab-guacd-sg` | 4822 from `lab-guac-sg` and `lab-guacd-nlb-sg` | guacd nodes |
| `lab-client-sg` | 3389 from `lab-guacd-sg` only. No SSH, no CIDR rules. | Kali clients |
| `lab-db-sg` | 5432 from `lab-guac-sg` | PostgreSQL |

### Parameters

| Parameter | Default | Notes |
|---|---|---|
| `LabPrefix` | `lab` | Prefix for names and export names |
| `VpcCidr` | `10.0.0.0/16` | Must be a `/16` |
| `Class1` / `Class2` / `Class3` | `31` / `32` / `33` | Third octet of each class subnet (PA31, PA32, PA33) |
| `Class1Az` / `Class2Az` / `Class3Az` | `0` / `1` / `2` | AZ index per class. Index 2 needs three AZs in the account. |

### Exports

All prefixed with `LabPrefix` (default `lab`):

`lab-VpcId`, `lab-VpcCidr`, `lab-AlbSubnetIds` (comma-separated), `lab-GuacSubnetIds` (comma-separated), `lab-ClassSubnet-PA31`, `lab-ClassSubnet-PA32`, `lab-ClassSubnet-PA33`, `lab-AlbSgId`, `lab-GuacSgId`, `lab-GuacdNlbSgId`, `lab-GuacdSgId`, `lab-ClientSgId`, `lab-DbSgId`

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

If your account has only two AZs in the region, set `Class3Az` to `0` or `1`:
`--parameter-overrides Class3Az=0`.

### Lint

```bash
pip install cfn-lint
cfn-lint cfn/01-network.yaml
```

### Verify after deploy

1. `aws cloudformation describe-stacks --stack-name lab-network --query 'Stacks[0].Outputs'` lists all exports.
2. Check the class subnets landed in different AZs:
   `aws ec2 describe-subnets --filters Name=tag:Lab,Values=guac --query 'Subnets[].[Tags[?Key==`Name`]|[0].Value,AvailabilityZone,CidrBlock]' --output table`
3. Launch a test instance in the PA31 subnet with a public IP and `lab-client-sg`. Confirm it can reach the internet.
4. Confirm 3389 is not reachable from outside `lab-guacd-sg`.
5. Delete the test instance.

---

## 02-platform.yaml

Permanent stack. Public entry point and shared services. Requires `lab-network`.

### Design decisions

- **The ALB is permanent and returns a friendly 503** until a web stack attaches. The web stack later adds its own target group and a listener rule, so the ALB, certificate and DNS never change between sessions.
- **No hardcoded domain or zone.** `DomainName` and `HostedZoneId` are required parameters with no defaults, supplied from `params/lab.env` at deploy time.
- **Secrets are permanent** (Secrets Manager, generated passwords), so a recreated database and the web nodes always agree after a restore.
- **No secret for the Kali desktop login.** It is the fixed `kali`/`kali` account. RDP is reachable only from the guacd security group, and each student's unique Guacamole password is the gatekeeper.
- **Least privilege per role.** Web nodes can read the DB secret and read/write the dump bucket. guacd nodes get SSM and CloudWatch only. Kali instances get no role.

### Resources

| Resource | Detail |
|---|---|
| ACM certificate | For `DomainName`, DNS-validated automatically in the hosted zone |
| ALB | Internet-facing, in the two ALB subnets, idle timeout 3600 s, invalid headers dropped |
| HTTPS listener (443) | TLS 1.3/1.2 policy, default action is a fixed 503 page |
| HTTP listener (80) | 301 redirect to HTTPS |
| Route53 record | A alias for `DomainName` pointing at the ALB |
| S3 bucket `lab-dumps-<account>-<region>` | Versioned, SSE-S3, public access blocked, TLS-only policy, `Retain` on stack deletion. Old versions expire after 90 days. |
| Secrets | `DbSecret` (user `guacamole`), `GuacAdminSecret` (user `guacadmin`) |
| IAM | `WebRole`/`WebInstanceProfile`, `GuacdRole`/`GuacdInstanceProfile` |

### Parameters

| Parameter | Default | Notes |
|---|---|---|
| `LabPrefix` | `lab` | Must match `01-network` |
| `DomainName` | none | Lab hostname. Supplied at deploy time. |
| `HostedZoneId` | none | Route53 zone serving the hostname. Supplied at deploy time. |

### Exports

`lab-DomainName`, `lab-HttpsListenerArn`, `lab-DumpBucketName`, `lab-DbSecretArn`, `lab-GuacAdminSecretArn`, `lab-WebInstanceProfileArn`, `lab-GuacdInstanceProfileArn`

### Deploy

```bash
source params/lab.env

aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name lab-platform \
  --template-file cfn/02-platform.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides DomainName="$LAB_DOMAIN" HostedZoneId="$LAB_HOSTED_ZONE_ID"

aws cloudformation update-termination-protection \
  --region "$AWS_REGION" --stack-name lab-platform --enable-termination-protection
```

Certificate validation can take a few minutes while the stack is `CREATE_IN_PROGRESS`.

### Verify after deploy

1. `curl -sI "https://$LAB_DOMAIN" | head -1` returns `HTTP/2 503` (DNS can take a few minutes to propagate).
2. `curl -sI "http://$LAB_DOMAIN" | head -1` returns a `301` redirect to HTTPS.
3. `aws cloudformation describe-stacks --stack-name lab-platform --query 'Stacks[0].Outputs'` lists the exports.

### Notes

- Keep termination protection on. Deleting this stack deletes the secrets, which would no longer match a restored database.
- Retrieve a password with `aws secretsmanager get-secret-value --secret-id <arn> --query SecretString --output text`.

---

## 03-storage.yaml

Permanent stack. An EFS file system holding the lecture notes that every Kali mounts read-only at `~/Desktop/notes`. Requires `lab-network` and `lab-platform`.

### Design decisions

- **Read-only is enforced by EFS, not by the client.** Students have root on their Kali, so a `ro` mount option alone could be undone with `mount -o remount,rw`. The file system policy allows `ClientMount` (read-only) to every NFS client, and `ClientWrite` plus `ClientRootAccess` only to the notes admin role (without root access, root on the admin instance is squashed and cannot write to the root-owned top level of the file system).
- **The policy is applied by a script**, `scripts/apply-notes-policy.sh`, because a policy inside this template cannot reference the file system's own ARN.
- **Kali needs no IAM role.** It mounts anonymously over NFS, so EFS cannot tell students apart. This is fine for shared, read-only notes. It is not suitable for private per-student files.
- **Master copy lives in S3** (`s3://<dump bucket>/notes/`), so the file system can always be rebuilt.
- **One mount target per AZ**, in the class subnets. This requires the three class subnets to be in three different AZs (the `01-network` default).

### Resources

| Resource | Detail |
|---|---|
| EFS file system `lab-notes` | Encrypted, Elastic throughput, automatic backups on |
| Mount targets | One in each class subnet, security group `lab-efs-sg` |
| `lab-efs-sg` | 2049 from `lab-client-sg` and the notes admin SG |
| `lab-notes-admin-sg` | No inbound rules; managed through SSM |
| `NotesAdminRole` / instance profile | SSM, EFS read/write on this file system, S3 read on `notes/` in the dump bucket |

### Parameters

| Parameter | Default | Notes |
|---|---|---|
| `LabPrefix` | `lab` | Must match the other stacks |
| `Class1` / `Class2` / `Class3` | `31` / `32` / `33` | Must match `01-network` |

### Exports

`lab-NotesFileSystemId`, `lab-NotesAdminRoleArn`, `lab-NotesAdminInstanceProfileArn`, `lab-NotesAdminSgId`

### Deploy

```bash
source params/lab.env

aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name lab-storage \
  --template-file cfn/03-storage.yaml \
  --capabilities CAPABILITY_IAM

scripts/apply-notes-policy.sh

aws cloudformation update-termination-protection \
  --region "$AWS_REGION" --stack-name lab-storage --enable-termination-protection
```

### Publish or update the notes

1. Find the dump bucket name (created by `02-platform`; it contains your account ID, so it is not written here) and copy the notes to its `notes/` prefix from your own machine (the master copy):
   ```bash
   source params/lab.env
   BUCKET=$(aws cloudformation list-exports --region "$AWS_REGION" \
     --query "Exports[?Name=='lab-DumpBucketName'].Value" --output text)
   aws s3 sync ./your-lecture-notes/ "s3://$BUCKET/notes/"
   ```
2. Launch a short-lived Amazon Linux 2023 instance and connect with SSM Session Manager. Settings: `t3.micro`; subnet `lab-guac-a` (first entry of the `lab-GuacSubnetIds` export) with a public IP (needed for the SSM agent, since there is no NAT); security group `lab-notes-admin-sg` (export `lab-NotesAdminSgId`, no inbound rules); instance profile from export `lab-NotesAdminInstanceProfileArn`; no key pair; IMDSv2 required with hop limit 1; tags `Name=notes-admin`, `Lab=guac`. Example:
   ```bash
   source params/lab.env; R=$AWS_REGION
   x() { aws cloudformation list-exports --region $R --query "Exports[?Name=='$1'].Value" --output text; }
   AMI=$(aws ssm get-parameter --region $R --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)
   aws ec2 run-instances --region $R --image-id $AMI --instance-type t3.micro \
     --subnet-id "$(x lab-GuacSubnetIds | cut -d, -f1)" \
     --security-group-ids "$(x lab-NotesAdminSgId)" \
     --iam-instance-profile Arn="$(x lab-NotesAdminInstanceProfileArn)" \
     --associate-public-ip-address \
     --metadata-options HttpTokens=required,HttpPutResponseHopLimit=1 \
     --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=notes-admin},{Key=Lab,Value=guac}]' \
     --query 'Instances[0].InstanceId' --output text
   aws ssm start-session --region $R --target <instance-id>   # needs the Session Manager plugin
   ```
3. On that Amazon Linux instance (hence `dnf`; the Kali instances mount over plain NFS with `nfs-common` and do not need `amazon-efs-utils`), set the bucket name and file system ID (the instance's role cannot look them up; get them from your machine with `list-exports`: `lab-DumpBucketName` and `lab-NotesFileSystemId`), then run:
   ```bash
   export AWS_DEFAULT_REGION=ap-southeast-1
   BUCKET=<lab-dumps-... name>
   FS=<fs-... id>

   sudo dnf install -y amazon-efs-utils
   sudo mkdir -p /mnt/notes
   sudo mount -t efs -o tls,iam "$FS":/ /mnt/notes
   sudo -E aws s3 sync "s3://$BUCKET/notes/" /mnt/notes/ --delete --dryrun   # preview
   sudo -E aws s3 sync "s3://$BUCKET/notes/" /mnt/notes/ --delete
   sudo chmod -R a+rX /mnt/notes
   ```
   `--delete` makes the file system an exact mirror of the S3 `notes/` prefix.
4. Terminate the instance.

### Verify (needs a running Kali, so after `20-class`)

1. On a Kali: `ls ~/Desktop/notes` shows the notes.
2. `sudo touch ~/Desktop/notes/test` fails (permission denied or read-only).
3. `sudo mount -o remount,rw ~/Desktop/notes && sudo touch ~/Desktop/notes/test` still fails. This proves the restriction is enforced by EFS.

If step 2 or 3 succeeds, the anonymous-client behaviour of the policy is not what we assumed. Fallback: have the Kali first-boot script sync the notes from S3 into a local folder instead of mounting EFS.