# IOTC
Lab automation for IOTC

## Files
```bash
├── create_guacamole_aws.yml
├── create_vpc.yml
├── generate_csv.yml
├── input
│   ├── PA31
│   └── PA32
├── labkey.pem
├── output
│   ├── PA31.csv
│   └── PA32.csv
├── process_one_file.yml
├── README.md
├── send_emails.yml
├── templates
│   ├── csv_template.j2
│   └── email_template.j2
└── vars
    ├── common.yml
    └── guacamole.yml
```

## Procedure

### Preparation

Prepare the user list.  The user lists is to be placed under the folder `input/`. 
The list shall be named according to the class, for example `PA31`.
The format of the class list shall be the email addresses of the users, one on each line.
Account of the instructor shall be placed right at the beginning of this file to cater for the instructor.

Run the playbook `generate_csv.yml` to process all input files to the output folder `output`.
```bash
ansible-playbook generate_csv.yml
```

The format of the output csv will be as follows.

```
s/n,email,password,ip
```
`s/n` starts from `0` which is meant for the instructor of the class.
`email` contains the email address of the user.
`password` is a randomly generated password for the user.
`ip` is the ip address of the client machine to be created for the user.

Additionally, we are using HTTPS to secure the access, hence the certificates for each of the domains required has to be prepared beforehand.  We are using AWS ACM for generating the public certificates.  DNS validation is performed for the certificate request.  We usea AWS Route53 therefore the validation is simply via the creation of Route53 record via the button at the ACM console.  

The infrastructure uses ELB to front the requests.  Therefore create the A record as an alias pointing to the ELB. A target group associated with the ELB has been created for each group.  On the ELB end, create the Listener rules to route to this target group.  Add the certificate which you have generated in the previous step as Listener certificates for SNI in the ELB Listener console.  


### Create the AWS networking infrastructure

Create the VPC, subnets and networking components required
```bash
ansible-playbook create_vpc.yml
```

### Create the guacamole server

Create the guacamole server for the group.  Adjust the variables in the following vars_files to set the variables for the group
```
common.yml
guacamole.yml
```

Specifically, ensure that the following is set in `vars/common.yml`:
```
group: "34"
```
`group` is the variable to set for which group this guacamole server is for.  For example if you are setting up for group `PA34`, you will set the group to `34`.

Set the following variables in `vars/guacamole.yml`:
```
guac_ipaddr: "10.0.0.34"
guac_subnet: "10.0.0.0/24"
```
`guac_ipaddr` is the internal ip address to allocate to the guacamole server.
`guac_subnet` is the subnet CIDR range to which to create this server in.

Setup the guacamole instance on AWS
```bash
ansible-playbook create_guacamole_aws.yml 
```

### Create the clients

After the guacamole server is up and running, you can create the clients for the users.
```bash
ansible-playbook launch_client_instances.yml
```
Register this guacamole server as the target for the appropriate target group. 
Reset the password for the admin user `guacamole` or create a new admin user and delete the original default.


### Setup guacamole users and connections

Setup your environment variables for the guacamole credentials.  
```bash
export GUAC_USER=mySuperSecretuser
export GUAC_PASS=mySuperSecurePW
```

Run the playbook to setup the guacamole users and connections.
```bash
ansible-playbook provisioning.yml 
```
Users should now be able to login their environment using the userid and password defined in `output/PAXX.csv` files.


### Send notification emails

This playbook uses AWS SES to send emails. As such you will need to setup credentials for SES.  Set the following environment variables.

```bash
 export SMTP_USERNAME=AKIAXXXXXXXXXX
 export SMTP_PASSWORD=superSecurePasswordStringwhichisVeryLong
```

Again the playbook relies on the `group` variable defined in `vars/common.yml` to send information based on the information on the appropriate `output/PAXX.csv` file. 

```bash
ansible-playbook send_emails.yml
```
