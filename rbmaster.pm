#
# This is the server-side implementation of Rockbuild.
#
# http://rockbuild.haxx.se
#
# Copyright (C) 2010-2012 Björn Stenberg
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
# KIND, either express or implied.
#
use DBI;

sub readconfig {
    %rbconfig = ();
    open(F, "<rbmaster.conf");
    while (<F>) {
        if (/^([^#]\w+):\s*(.+)/) {
            $rbconfig{$1} = $2;
            chomp $rbconfig{$1};
        }
    }
    close F;
}


sub getbuilds {
    my $filename="builds";

    %builds = ();
    @buildids = ();

    open(F, "<$filename");
    while(<F>) {
        # arm-eabi-gcc444:0:ipodnano1gboot:iPod Nano 1G - Boot:bootloader-ipodnano1g.ipod:839:../tools/configure --target=ipodnano1g --type=b && make
        next if (/^\#/);
        chomp;
        my ($arch, $upload, $id, $name, $result, $score,
            $cmdline) = split(':', $_);
        $builds{$id}{'arch'}=$arch;
        $builds{$id}{'upload'}=$upload;
        $builds{$id}{'name'}=$name;
        $builds{$id}{'result'}=$result;
        $builds{$id}{'score'}=$score;
        $builds{$id}{'cmdline'}=$cmdline;
        $builds{$id}{'handcount'} = 0; # not handed out to anyone
        $builds{$id}{'assigned'} = 0; # not assigned to anyone
        $builds{$id}{'done'} = 0; # not done
        $builds{$id}{'uploading'} = 0; # not uploading
        $builds{$id}{'ulsize'} = 0;
        $buikds{$id}{'topspeed'} = 0;

        push @buildids, $id;
    }
    close(F);

    my @s = sort {$builds{$b}{score} <=> $builds{$a}{score}} keys %builds;
    $topscore = int($builds{$s[0]}{score} / 2);

    return if ($rbconfig{test});

    if (not $db) {
        db_connect();
        db_prepare();
    }

    # get last revision
    my $rows = $getlastrev_sth->execute();
    ($lastrev) = $getlastrev_sth->fetchrow_array();
    $getlastrev_sth->finish();

    # get last sizes
    $rows = $getsizes_sth->execute($lastrev);
    while (my ($id, $size) = $getsizes_sth->fetchrow_array())
    {
        $builds{$id}{ulsize} = $size;
    }
    $getsizes_sth->finish();
}


sub getspeed($)
{
    return (0,0) if ($rbconfig{test});
    if (not $db) {
        db_connect();
        db_prepare();
    }

    my ($cli) = @_;

    my $rows = $getspeed_sth->execute($cli, 10);
    if ($rows > 0) {
        my @ulspeeds;
        my @buildspeeds;

        # fetch score for $avgcount latest revisions (build rounds)
        while (my ($id, $buildtime, $ultime, $ulsize) = $getspeed_sth->fetchrow_array()) {
            my $points = $builds{$id}{score};
            push @buildspeeds, int($points / $buildtime);

            if ($ulsize && $ultime) {
                push @ulspeeds, int($ulsize / $ultime);
            }

        }
        $getspeed_sth->finish();

        my $bs = 0;
        my $us = 0;

        if (0) {
            # get the "33% median" speed
            $bs = (sort {$a <=> $b} @buildspeeds)[scalar @buildspeeds / 3];
            $us = (sort {$a <=> $b} @ulspeeds)[scalar @ulspeeds / 3];
        }
        else {
            if (scalar @buildspeeds) {
                ($bs += $_) for @buildspeeds;
                my $bcount = scalar @buildspeeds;
                $bs /= $bcount;
            }
            if (scalar @ulspeeds) {
                ($us += $_) for @ulspeeds;
                $us /= scalar @ulspeeds;
            }
        }
        
        return (int $bs, int $us);
    }
    return (0, 0);
}

sub db_connect
{
    return if ($rbconfig{test});
    readconfig() if (not $rbconfig{dbname});

    my $dbpath = "DBI:$rbconfig{dbtype}:database=$rbconfig{dbname};host=$rbconfig{dbhost}";
    $db = DBI->connect($dbpath, $rbconfig{dbuser}, $rbconfig{dbpwd},
                       {mysql_auto_reconnect => 1}) or
        warn "DBI: Can't connect to database: ". DBI->errstr;
}

sub db_prepare
{
    return if ($rbconfig{test});
    # prepare some statements for later execution:

    $submit_update_sth = $db->prepare("UPDATE builds SET client=?,timeused=?,ultime=?,ulsize=? WHERE revision=? and id=?") or
        warn "DBI: Can't prepare statement: ". $db->errstr;

    $submit_new_sth = $db->prepare("INSERT INTO builds (revision,id) VALUES (?,?) ON DUPLICATE KEY UPDATE client='',timeused=0,ultime=0,ulsize=0") or
        warn "DBI: Can't prepare statement: ". $db->errstr;

    $setlastrev_sth = $db->prepare("INSERT INTO clients (name, lastrev) VALUES (?,?) ON DUPLICATE KEY UPDATE lastrev=?") or
        warn "DBI: Can't prepare statement: ". $db->errstr;

    $getspeed_sth = $db->prepare("SELECT id, timeused, ultime, ulsize FROM builds WHERE client=? AND errors = 0 AND warnings = 0 AND timeused > 5 ORDER BY time DESC LIMIT ?") or
        warn "DBI: Can't prepare statement: ". $db->errstr;

    $getlastrev_sth = $db->prepare("SELECT revision FROM builds ORDER BY time DESC LIMIT 1") or
        warn "DBI: Can't prepare statement: ". $db->errstr;

    $getsizes_sth = $db->prepare("SELECT id,ulsize FROM builds WHERE revision = ?") or
        warn "DBI: Can't prepare statement: ". $db->errstr;

    $dblog_sth = $db->prepare("INSERT INTO log (revision,client,type,value) VALUES (?,?,?,?)") or
        warn "DBI: Can't prepare statement: ". $db->errstr;
}

sub nicehead {
    my ($title)=@_;

    open(READ, "<head.html");
    while(<READ>) {
        s/_PAGE_/$title/;
        print $_;
    }
    close(READ);

}

sub nicefoot {
    open(READ, "<foot.html");
    while(<READ>) {
        print $_;
    }
    close(READ);
}

1;
