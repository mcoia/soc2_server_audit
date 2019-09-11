# SOC2 Server Audit

## Main Idea

These are the main tenants:

1. Automated server health checks and differencing. 
2. Create an automated way to reach out to any number of servers and gather a huge amount of data. 
3. Parse the data, sift the data and report the important things!

This software will reachout to a provided list of servers and do the following:

1. Install Lynis
2. Install AIDE
3. Run Lynis and AIDE
4. Retrieve the results and save them locally
5. Parse the outputs and impor them into a PostgreSQL database
6. Run reports from the database and email them to destinations of your chosing


## Assumptions

We assume you have a basic understanding of Linux machines. SSH connections and key pairing. Ansible will require that the machine you run this upon has key authentication with each of the servers that it's connecting.

## Prerequisites

The server that this runs on will need at a minimum:
- Ansible
- Perl modules
  - DBD::Pg
  - Encode
  - utf8
  - Data::Dumper
  - File::Copy
- SSH keys setup to each destination server

## Getting started

- Decide on a place to have the software run
- Clone this project
- Install PostgreSQL somewhere (same machine is fine)
- Edit these files:
  - conf.soc2
  - hosts
  - aide/aide_fetch_report_playbook.yml
  - lynis/lynis_fetch_report_playbook.yml
  - run_soc2
  - dockerguests (optional)
  - aide/conf.aide (optional)

NOTE: Each file is detailed below
  
### PostgreSQL

```
$ psql -d template1 -U postgres 
template1=# CREATE USER soc2 WITH PASSWORD 'dbpassword'; 
template1=# CREATE DATABASE soc2;
template1=# GRANT ALL PRIVILEGES ON DATABASE soc2 to soc2;
\q
# verify listen_address='*' in postgresql.conf
# add this to pg_hba.conf:
#   host    all             all              0.0.0.0/0                       md5
# Restart postgres if you changed any of postgres's configs

```
NOTE: ***If you use a different databaes name, you will need to edit references in soc2.pl***


### EDIT FILE conf.soc2

This is the main config file.

 - PostgreSQL database connections.
 - Log output path.
 - Paths to lynis and aide outputs.
 - Email options.

```
lynis_reports_path=/path/to/lynis
aide_reports_path=/path/to/aide
```

### EDIT FILE aide_fetch_report_playbook.yml / lynis_fetch_report_playbook.yml

You need only edit the path to where you want the outputs to go:

```
lynis_report_local_destination: /path/to/lynis
and
aide_report_local_destination: "/path/to/aide"

```

Respectively

NOTE: These paths need to match the paths from conf.soc2


### EDIT FILE hosts / dockerguests (optional)

These are ansible files. Follow the examples in these files. Ansible has a weird issue when running the same job on the same machine with two different ssh ports. You have to break out any docker guests you might have into a seperate file when they are inside of another machine with the same connection name but on a different port obviously.


### EDIT FILE aide/conf.aide (optional)

This is an AIDE specific file. This allows you to customize the files that AIDE is allowed to report on. This is where you would teach it to ignore stuff that changes all the time and you don't want to hear about everytime! This file is seeded with sane defaults.

### EDIT FILE run_soc2

This is the shell wrapper script for running the whole thing.

NOTE: These lines in particular


 ***lynis_reports_path="/path/to/lynis"***
 ***aide_reports_path="/path/to/aide"***

 ***cd /path/to/here/soc2_server_audit/lynis***
 ***cd /path/to/here/soc2_server_audit/aide***


```
lynis_reports_path="/path/to/lynis"
aide_reports_path="/path/to/aide"

rm -Rf "$lynis_reports_path"/*
rm -Rf "$aide_reports_path"/*

cd /path/to/here/soc2_server_audit/lynis
ansible-playbook lynis_fetch_report_playbook.yml -i ../hosts  -v
ansible-playbook lynis_fetch_report_playbook.yml -i ../dockerguests  -v

cd /path/to/here/soc2_server_audit/aide
ansible-playbook aide_fetch_report_playbook.yml -i ../hosts  -v
ansible-playbook aide_fetch_report_playbook.yml -i ../dockerguests  -v

cd ../
./soc2.pl --config conf.soc2

```

There are many options you can pass to the perl script. The default is --config.
Lifted from the script:

```perl
--config configfilename                       [Path to the config file - required]             
--debug flag                                  [Cause more logging output]
--reset flag                                  [Empty out the schema table]
--reportonly flag                             [Skip everything and only run a report - Reports are always run at the end]
--job integer                                 [Usually used in conjunction with reportonly. It will spit out the report for that job. Last job is default]
```

NOTE: --reset will delete all data

