# Guacamole Kali Lab on AWS

Browser-based Kali Linux labs on AWS: Apache Guacamole behind an ALB connects to per-student Kali desktops over RDP. This README is updated as each part is built.

- **Region:** ap-southeast-1
- **IaC:** CloudFormation

## Status

| Component | State |
|---|---|
| `cfn/01-network.yaml` | Deployed as stack `lab-network` in ap-southeast-1. |
| `cfn/02-platform.yaml` | Deployed as stack `lab-platform` in ap-southeast-1. |
| `cfn/03-storage.yaml` | Deployed as stack `lab-storage`; notes published; read-only policy applied by `scripts/apply-notes-policy.sh`. Read-only behaviour on a Kali client not yet verified. |
| `ami/kali-firstboot.sh` | Written. Logic tested manually on a Kali instance. Runs from the class stack's user data; its results (hostname, notes mount) not yet checked on a deployed Kali. |
| `cfn/10-database.yaml` | Deployed as stack `lab-database`. Ephemeral (per session). |
| `cfn/11-web.yaml` | Deployed as stack `lab-web`; both targets healthy; admin login works after `scripts/db-run.sh init`. Ephemeral (per session). |
| `cfn/20-class.yaml` | Deployed as stack `lab-class-pa31`; an RDP session from Guacamole to a Kali opens with no password prompt. Ephemeral (one stack per class). |

## Repo layout

```
cfn/
  01-network.yaml    VPC, subnets, routing, security groups
  02-platform.yaml   ALB, ACM cert, Route53 record, S3 dump bucket, secrets, IAM
  03-storage.yaml    EFS for read-only lecture notes, mount targets, notes admin role
  10-database.yaml   RDS PostgreSQL for Guacamole (ephemeral, per session)
  11-web.yaml        Guacamole web ASG, target group, ALB listener rule (ephemeral, per session)
  20-class.yaml      per class: guacd pool + internal NLB, one Kali per student index (ephemeral)
ami/
  kali-firstboot.sh  user-data for Kali instances (password, compositor, hostname, notes mount)
scripts/
  db-run.sh               runs db tasks (init / restore / dump) on a web node via SSM
  node/db-node.sh         the task itself; runs on the web node
  deploy-class.sh         deploys/updates one class stack from Guacamole's connection list
  sync_guac.py            roster -> Guacamole users, connections, permissions (REST API)
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

---

## 10-database.yaml

Ephemeral stack, created at spin-up and deleted at teardown. Stack numbering: `0x` are permanent, `1x` are shared per-session stacks, `2x` are per-class stacks. Requires `lab-network` and `lab-platform`.

### Design decisions

- **Single-AZ.** A database outage only blocks new logins and new connection starts. Live sessions keep running, because the database is not in the data path.
- **Credentials come from the permanent `DbSecret`** (created by `02-platform`), so a recreated database and the web nodes always agree on the password.
- **The SQL dump in S3 is the primary restore path.** Deleting the stack also leaves a final RDS snapshot as a safety net.
- **Exports are consumed by the web stack,** so the web stack must be deleted before this one (CloudFormation refuses to delete an export that is in use).
- **Dump and restore scripts arrive with the web stack,** because they run on a web node (the only machine with network access to the database).

### Resources

| Resource | Detail |
|---|---|
| DB subnet group | The two ALB subnets (two AZs, as RDS requires) |
| RDS PostgreSQL instance | `db.t4g.micro`, 20 GB gp3, encrypted, not publicly accessible, 1-day automated backups |
| Security group | `lab-db-sg` from `01-network`: 5432 from the web nodes only |
| Deletion behaviour | `DeletionPolicy: Snapshot` (final snapshot kept) |

### Parameters

| Parameter | Default | Notes |
|---|---|---|
| `LabPrefix` | `lab` | Must match the other stacks |
| `DbInstanceClass` | `db.t4g.micro` | |
| `EngineVersion` | `16` | Major only lets RDS pick the current minor. Use a full version to pin. |
| `AllocatedStorage` | `20` | GB |
| `MultiAz` | `false` | |
| `DbName` | `guacamole_db` | |

### Exports

`lab-DbEndpoint`, `lab-DbPort`, `lab-DbName`

### Deploy

```bash
source params/lab.env

aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name lab-database \
  --template-file cfn/10-database.yaml
```

Creation takes several minutes.

### Verify after deploy

1. `aws rds describe-db-instances --region "$AWS_REGION" --query "DBInstances[?contains(DBInstanceIdentifier,'lab-database')].[DBInstanceStatus,Endpoint.Address]" --output text` shows `available` and an endpoint.
2. The three exports above exist (`aws cloudformation list-exports`).

### Teardown

Delete this stack after the web stack. A final snapshot is created; list and clean up old ones:

```bash
aws rds describe-db-snapshots --region "$AWS_REGION" --snapshot-type manual \
  --query "DBSnapshots[].[DBSnapshotIdentifier,SnapshotCreateTime]" --output table
```

Snapshots cost storage until deleted.

---

## 11-web.yaml

Ephemeral stack. Requires `lab-network`, `lab-platform` and `lab-database`. Delete it before `lab-database`.

### Design decisions

- **Docker on stock Amazon Linux 2023.** The node installs Docker at boot and runs one pinned `guacamole/guacamole` container. No custom AMI yet.
- **No guacd here.** Each class stack has its own guacd pool. The container still requires `GUACD_HOSTNAME` to start, so it is set to an unused `127.0.0.1`; the per-connection proxy hostname stored in the database (set by the sync script) is what actually routes sessions.
- **Two nodes, one per AZ,** behind the permanent ALB. Target group uses a load-balancer cookie for stickiness so a user's requests stay on one node.
- **Database credentials are fetched from Secrets Manager at boot** and written to `/etc/guacamole.env` (mode 600). Nothing sensitive is in the template.
- **TLS to the database is required** (`POSTGRESQL_SSL_MODE=require`), as current RDS PostgreSQL versions enforce SSL.
- **IMDSv2 only with hop limit 1,** so the container cannot obtain the node's IAM role credentials.
- **Public IP on the node** (no NAT) so it can pull the image; inbound is limited to the ALB by `lab-guac-sg`.
- **The ALB rule forwards only the lab hostname.** Other requests keep the 503 default.

### Resources

| Resource | Detail |
|---|---|
| Launch template | AL2023 (SSM-resolved AMI), `c6i.large`, 16 GB encrypted gp3, `lab-guac-sg`, web instance profile |
| Auto Scaling group | min 2 / max 2 across the two guac subnets, ELB health checks, rolling update |
| Target group | HTTP 8080, health check `/` expecting 200, cookie stickiness, 30 s deregistration delay |
| Listener rule | Priority 10 on the HTTPS listener, host header = the lab domain |

### Parameters

| Parameter | Default | Notes |
|---|---|---|
| `LabPrefix` | `lab` | Must match the other stacks |
| `WebInstanceType` | `c6i.large` | x86 only |
| `WebMinSize` / `WebMaxSize` | `2` / `2` | |
| `GuacamoleImage` | `guacamole/guacamole:1.6.0` | Pinned; version documented in the Guacamole manual |
| `AmiId` | SSM path for AL2023 x86_64 | Resolved at deploy time |

### Exports

`lab-WebTargetGroupArn`, `lab-WebAsgName`

### Deploy

```bash
source params/lab.env

aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name lab-web \
  --template-file cfn/11-web.yaml
```

### Verify after deploy

1. Targets become `healthy`: `aws elbv2 describe-target-health --region "$AWS_REGION" --target-group-arn $(aws cloudformation list-exports --region "$AWS_REGION" --query "Exports[?Name=='lab-WebTargetGroupArn'].Value" --output text)`
2. Boot log on a node (via SSM Session Manager): `/var/log/lab-web-boot.log`, then `sudo docker logs guacamole`.
3. Opening the lab domain in a browser shows the Guacamole page. The database is still empty at this point, so login will not work until the schema is initialised or a dump is restored (next step, not yet built).

### Teardown

```bash
aws cloudformation delete-stack --region "$AWS_REGION" --stack-name lab-web
```

---

## Database tasks (`scripts/db-run.sh`)

Run from your machine. The script picks one in-service web node, runs the task there through SSM Session Manager's run-command (the web nodes are the only machines that can reach the database), then restarts Guacamole on all web nodes. Run it once per session, after `lab-web` is up.

```bash
source params/lab.env
scripts/db-run.sh init                    # empty database: load schema, set guacadmin password
scripts/db-run.sh restore [file-name]     # empty database: restore newest (or named) dump, set guacadmin password
scripts/db-run.sh dump                    # write s3://<dump bucket>/dumps/guacamole-<timestamp>.sql.gz
```

- `init` and `restore` refuse to run if the database already has tables.
- The `guacadmin` password is set from the permanent `GuacAdminSecret` after every init or restore. Read it with `aws secretsmanager get-secret-value --secret-id <GuacAdminSecretArn> --query SecretString --output text`.
- Dumps use `pg_dump --no-owner --no-acl` (this database only).
- The web role needs read access to `GuacAdminSecret`; redeploy `lab-platform` after pulling this change (`--capabilities CAPABILITY_IAM`).
- Status: `init`, `dump` and `restore` tested (users survive a delete and redeploy of `lab-web` and `lab-database`). Make every change you want to keep, then run `dump` as the last step before teardown.

---

## Roster sync (`scripts/sync_guac.py`)

Reads a roster CSV (`class,email,name`; format example in `params/roster.example.csv`) and creates, through Guacamole's REST API, the users, RDP connections, READ permissions and class groups. Run from your machine after the database is restored. Needs the AWS CLI configured and `LAB_DOMAIN` / `AWS_REGION` from `params/lab.env`.

```bash
source params/lab.env
scripts/sync_guac.py roster/roster.csv --dry-run          # show the plan, change nothing
scripts/sync_guac.py roster/roster.csv
scripts/sync_guac.py --reset someone@example.com          # new password for one existing user
scripts/sync_guac.py --show someone@example.com           # what can this user see? (read-only)
scripts/sync_guac.py --list-class PA31                    # indexes with a connection, e.g. 1,2,3 (read-only)
```

- **Users:** the email is the Guacamole username, with a random 14-character password. The roster name is stored as the user's full name (shown in the user menu after login) and the email as the email address. These are set when the user is created only.
- **Index and IP:** each new student gets the next free index in the class (existing connections are read back from Guacamole). The Kali IP is `10.0.<class>.(100+index)`. A connection is named `<CLASS>-S<NN> <email>`, and that name is how an existing student is recognised on later runs.
- **Routing:** each connection points at the student's Kali (RDP, shared `kali` desktop login, low-bandwidth settings) and carries the per-connection guacd override `10.0.<class>.10:4822`, which sends the session to that class's guacd pool.
- **Visibility:** a student has READ on their own connection only and no system permissions. Checked with `--show`: direct and effective (including group) permissions list only that one connection.
- **Class groups:** `PA31` / `PA32` / `PA33`, for admin convenience. Groups carry no permissions. If the group calls fail, the script warns and continues without them.
- **Never touched:** existing users keep their password and details. Nothing is ever deleted by the script. A new user always receives READ on their connection, including when the connection already existed (for example after a user was deleted and re-created).
- **Moving classes:** a student whose email already has a connection in another class stops the run; resolve it by hand.
- **Output** goes to `roster/out/` (git-ignored, mode 600): `credentials-<timestamp>.csv` (new users only; the only copy of the plaintext passwords) and `assignments-<timestamp>.csv` (class, index, IP, email, name for every roster row). Timestamps include the time so a second run never overwrites an earlier credentials file.
- **After a sync,** run `scripts/db-run.sh dump` so the new users are in the next restore.
- **Test data:** before real students are loaded, deleting all test users and connections in the admin UI resets the numbering to 1. Once real students exist, do not delete connections: the index (and with it the Kali IP) is derived from them and must stay stable for the semester.

### Notes from testing

- The web tier has two nodes and a Guacamole login token only exists on the node that issued it, so API calls must stay on one node. The script keeps the ALB stickiness cookie for this. Any other client calling the API (for example curl) needs a cookie jar (`-c` / `-b`), otherwise calls fail randomly with `403 Permission Denied`.
- Status: tested against a live Guacamole: users, names, connections, per-user visibility and re-running without changes. The connection itself has not been opened yet (needs the class stack with guacd and Kali).

---

## 20-class.yaml

Ephemeral stack, one per class (`lab-class-pa31`, `lab-class-pa32`, `lab-class-pa33`), deployed with `scripts/deploy-class.sh`. Requires `lab-network`, `lab-platform` and `lab-storage`. Classes are independent: start and delete them one at a time. Delete a class stack first in the teardown order, after `db-run.sh dump`.

### What it builds

| Resource | Detail |
|---|---|
| Internal NLB | Fixed address `10.0.<class>.10`, TCP 4822, in the class subnet; security group `lab-guacd-nlb-sg` (4822 from the web nodes only) |
| guacd pool | Auto Scaling group in the class subnet, default 2 x `c6i.large`, Amazon Linux 2023 with the pinned `guacamole/guacd` container, TCP health check on 4822 |
| Kali desktops | One EC2 instance per student index at `10.0.<class>.(100+index)`, from the golden AMI, client security group (RDP from guacd only), public IP for outbound internet only, instance metadata tags on, no instance profile |

- The Kali user data is `ami/kali-firstboot.sh`. `deploy-class.sh` gzips and base64-encodes it into a parameter (about 2 KB, limit 4096) and the instance decodes and runs it, with `EFS_ID` and `REGION` supplied by the template. Root volume size is the AMI's own.
- CloudFormation has no arithmetic and the loop value cannot be used as a `FindInMap` key (the first deploy attempt failed on exactly that), so `deploy-class.sh` does the arithmetic: it converts each index to its last octet (`100 + index`, the same rule as `sync_guac.py`) and passes the octets to the stack.
- The Kali instances are created by a loop (`Fn::ForEach`, transform `AWS::LanguageExtensions`) over the `KaliHostOctets` parameter, with the loop value read inside the body as `!Ref Octet`, which is the form AWS documents (a quoted `${Octet}` string is replaced only in the resource name and in `Fn::Sub` strings, not inside `Fn::Join`; the second deploy attempt failed on that). Instances are named `pa<class>-<last octet>` (for example `pa31-101` for student index 1); the first-boot script uses that as the hostname.

### Parameters

| Parameter | Default | Notes |
|---|---|---|
| `ClassOctet` | none | `31`, `32` or `33` (PA31, PA32, PA33). `deploy-class.sh` sets it from the class you name |
| `KaliHostOctets` | none | Comma-separated last octets (101 to 254), one Kali each. `deploy-class.sh` builds it from the indexes in Guacamole (every connection in the class) |
| `KaliAmiId` | none | From `LAB_KALI_AMI_ID` in `params/lab.env`; different labs can use different images |
| `KaliInstanceType` | `t3.small` | `KALI_INSTANCE_TYPE` |
| `GuacdInstanceType` | `c6i.large` | `GUACD_INSTANCE_TYPE`; compute-optimised x86, avoid burstable types for guacd |
| `GuacdMinSize` / `GuacdMaxSize` | `2` / `2` | `GUACD_COUNT` |
| `GuacdImage` | `guacamole/guacd:1.6.0` | Keep in step with the web image |

### Deploy

```bash
source params/lab.env            # needs LAB_KALI_AMI_ID
scripts/deploy-class.sh PA31                  # every student with a connection
scripts/deploy-class.sh PA31 --indexes 1,2,3  # only these (for tests)
scripts/deploy-class.sh PA31 --extra-script labs/web-sec.sh   # optional lab-specific commands
```

Order in a session: database, web, `db-run.sh restore`, `sync_guac.py`, then this. The script prints the plan (count, indexes, addresses) and asks for confirmation. Re-running it after the roster grows adds the new Kali and leaves the others alone. Anyone with a connection gets a Kali; revoke exceptions in the Guacamole admin UI.

`--extra-script` is optional (nothing changes without it). The file is appended to `kali-firstboot.sh` and runs after it, in the same shell as root, with `set -u` still on; the combined, compressed script must stay under 4096 characters (about 2 KB is used by the first-boot script alone) and the script stops with an error if it does not. User data runs only at an instance's first boot, so if the script differs from the one in the running stack, `deploy-class.sh` warns that every Kali instance will be replaced (student files lost) and asks for a second confirmation.

### Checking the template

`cfn-lint` cannot expand a loop whose list is a parameter, so it reports the loop placeholders as errors. To lint the loop body, expand it by hand for a few indexes and lint the result; the last such check was clean (only the expected "parameter not used" warning).

### Teardown

```bash
scripts/db-run.sh dump
aws cloudformation delete-stack --region "$AWS_REGION" --stack-name lab-class-pa31
```

### Verified

- A student connection opened from Guacamole reaches the Kali through the NLB and a guacd node, and logs in with no password prompt at the RDP screen (the connection carries the shared `kali` login).

### Not yet verified

- xrdp session reattach after a disconnect.
- The read-only notes mount on a Kali (writes must be refused), and the hostname set from the instance Name tag.
- Load: guacd CPU with a full class of simultaneous sessions.