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

    system("svn up -q --non-interactive $filename");

    open(F, "<$filename");
    while(<F>) {
        # sh:rockbox.zip:archosrecorder:Recorder - Normal:ajbrec.ajz:tools/configure --target=archosrecorder --ram=2 --type=n:make zip:10478
        next if (/^#/);
        chomp;
        my ($arch, $upload, $id, $name, $result,
            $configure, $makeupload, $score) = split(':', $_);
        $builds{$id}{'arch'}=$arch;
        $builds{$id}{'upload'}=$upload;
        $builds{$id}{'name'}=$name;
        $builds{$id}{'result'}=$result;
        $builds{$id}{'configure'}=$configure;
        $builds{$id}{'makeupload'}=$makeupload;
        $builds{$id}{'score'}=$score;
        $builds{$id}{'handcount'} = 0; # not handed out to anyone
        $builds{$id}{'assigned'} = 0; # not assigned to anyone
        $builds{$id}{'done'} = 0; # not done
        $builds{$id}{'uploading'} = 0; # not uploading
        $builds{$id}{'ulsize'} = 0;

        push @buildids, $id;
    }
    close(F);

    my @s = sort {$builds{$b}{score} <=> $builds{$a}{score}} keys %builds;
    $topscore = int($builds{$s[0]}{score} / 2);

    return if ($test);

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
    return (0,0) if ($test);
    if (not $db) {
        db_connect();
        db_prepare();
    }

    my ($cli) = @_;

    my $rows = $getspeed_sth->execute($cli, $lastrev-5);
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
                if ($bcount < $rounds) {
                    $bcount = $rounds;
                }
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
    return if ($test);

    my $dbpath = "DBI:$rbconfig{dbtype}:database=$rbconfig{dbname};host=$rbconfig{dbhost}";
    $db = DBI->connect($dbpath, $rbconfig{dbuser}, $rbconfig{dbpwd}) or
        warn "DBI: Can't connect to database: ". DBI->errstr;
}

sub db_prepare
{
    # prepare some statements for later execution:

    $submit_update_sth = $db->prepare("UPDATE builds SET client=?,timeused=?,ultime=?,ulsize=? WHERE revision=? and id=?") or
        warn "DBI: Can't prepare statement: ". $db->errstr;

    $submit_new_sth = $db->prepare("INSERT INTO builds (revision,id) VALUES (?,?) ON DUPLICATE KEY UPDATE client='',timeused=0,ultime=0,ulsize=0") or
        warn "DBI: Can't prepare statement: ". $db->errstr;

    $setlastrev_sth = $db->prepare("INSERT INTO clients (name, lastrev) VALUES (?,?) ON DUPLICATE KEY UPDATE lastrev=?") or
        warn "DBI: Can't prepare statement: ". $db->errstr;

    $getspeed_sth = $db->prepare("SELECT id, timeused, ultime, ulsize FROM builds WHERE client=? AND timeused > 0 AND revision >= ?") or
        warn "DBI: Can't prepare statement: ". $db->errstr;

    $getlastrev_sth = $db->prepare("SELECT revision FROM builds ORDER BY revision DESC LIMIT 1") or
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
