# IOTC
Lab automation for IOTC

## Files
```bash
├── IOTC
│   ├── create_vpc.yml
│   ├── generate_csv.yml
│   ├── input
│   │   ├── PA31
│   │   └── PA32
│   ├── output
│   │   ├── PA31.csv
│   │   └── PA32.csv
│   ├── process_one_file.yml
│   ├── README.md
│   ├── send_emails.yml
│   ├── templates
│   │   ├── csv_template.j2
│   │   └── email_template.j2
│   └── vars
│       └── common.yml
└── README.md
```

## Procedure
Create the VPC, subnets and networking components required
```bash
ansible-playbook create_vpc.yml
```
Generate users' credential files
```bash
ansible-playbook generate_csv.yml
```

Send email to inform users
```bash
ansible-playbook send_emails.yml
```