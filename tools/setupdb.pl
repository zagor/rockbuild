#!/usr/bin/perl

if (scalar @ARGV < 2) {
    print "usage: perl setupdb.pl [dbadminuser] [dbadminpasswd]\n";
    exit;
}

my $dbadminuser = $ARGV[0];
my $dbadminpwd = $ARGV[1];

require 'rbmaster.pm';

readconfig();

# create database
my $dbpath = "DBI:$rbconfig{dbtype}:host=$rbconfig{dbhost}";
my $db = DBI->connect($dbpath, $dbadminuser, $dbadminpwd) or
    die "Admin can't connect to database server";

print "> CREATE DATABASE $rbconfig{dbname}\n";
$db->do("CREATE DATABASE $rbconfig{dbname}") or
    die "Can't create database". DBI->errstr;

print "> CREATE USER $rbconfig{dbuser}\@$rbconfig{dbhost} IDENTIFIED BY '$rbconfig{dbpwd}'\n";
$db->do("CREATE USER $rbconfig{dbuser}\@$rbconfig{dbhost} IDENTIFIED BY ?",
        undef, $rbconfig{dbpwd}) or
    die "Can't grant privileges";


print "> GRANT ALL ON $rbconfig{dbname}.* TO $rbconfig{dbuser}\@$rbconfig{dbhost}\n";
$db->do("GRANT ALL ON $rbconfig{dbname}.* TO $rbconfig{dbuser}\@$rbconfig{dbhost}") or
    die "DBI: Can't create user";

$db->disconnect();

db_connect();

print "> CREATE TABLE builds\n";
$db->do("CREATE TABLE builds ( ".
        "time timestamp NOT NULL ON UPDATE CURRENT_TIMESTAMP,".
        "revision int(9) NOT NULL,".
        "id varchar(64) NOT NULL,".
        "client varchar(64) NOT NULL,".
        "timeused decimal(6,2) NOT NULL,".
        "bogomips int(9) NOT NULL,".
        "ultime int(9) NOT NULL,".
        "ulsize int(9) NOT NULL,".
        "errors int(9) NOT NULL DEFAULT 1,".
        "warnings int(9) NOT NULL,".
        "ramsize int(9) NOT NULL,".
        "binsize int(9) NOT NULL,".
        "PRIMARY KEY (revision,id),".
        "KEY revision (revision),".
        "KEY id (id),".
        "KEY client (client)".
        ")") or
    die "Can't create table 'builds'";

print "> CREATE TABLE clients\n";
$db->do("CREATE TABLE clients (".
        "name varchar(32) NOT NULL,".
        "lastrev int(9) NOT NULL,".
        "totscore int(9) NOT NULL,".
        "builds int(9) NOT NULL,".
        "blocked int(1) NOT NULL,".
        "PRIMARY KEY (name),".
        "KEY lastrev (lastrev),".
        "KEY name (name)".
        ")") or
    die "Can't create table 'clients'";

print "> CREATE TABLE log\n";
$db->do("CREATE TABLE log (".
        "revision int(9) NOT NULL,".
        "time timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,".
        "client varchar(32) NOT NULL,".
        "type varchar(16) NOT NULL,".
        "value varchar(128) NOT NULL,".
        "KEY revision (revision),".
        "KEY client (client)".
        ")") or
    die "Can't create table 'log'";
    

print "> CREATE TABLE rounds\n";
$db->do("CREATE TABLE rounds (".
        "revision int(9) NOT NULL,".
        "took int(9) NOT NULL,".
        "clients int(9) NOT NULL,".
        "PRIMARY KEY (revision),".
        "KEY revision (revision)".
        ")") or
    die "Can't create table 'rounds'";

$db->disconnect();
