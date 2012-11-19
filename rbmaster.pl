#!/usr/bin/perl -w
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

use strict;

# the name of the server log
our $logfile="logfile";

# read client block list every 10 minutes
our $lastblockread = 0;

use IO::Socket;
use IO::Select;
use Net::hostent;
use File::Path;
use DBI;
use Time::HiRes qw(gettimeofday tv_interval);
use POSIX 'strftime';

require 'rbmaster.pm';

# Each active connection gets an entry here, keyed by its filedes.
my %conn;

# this is $rev while we're in a build round, 0 otherwise
my $buildround;

# revision to build after the current buildround.
# if several build requests are recieved during a round, we only keep the last
my $nextround;

#
# {$fileno}{'cmd'} for building incoming commands
#  {'client'} 
#  {'archs'} 
#  {'cpu'} - string for stats
#  {'bits'} 32 / 64 
#  {'os'}
#

my $started = time();
my $wastedtime = 0; # sum of time spent by clients on cancelled builds

our ( $setlastrev_sth, $dblog_sth, $submit_update_sth, $submit_new_sth);
our %rbconfig;
our %builds;
our %client;
our @buildids;
our %blocked;
our %buildclients; # clients involved this round
our $buildstart;
our $estimated_time;
our $speculative;
our $db;
our $abandoned_builds;
our $idle_clients;
our %buildtimes;

sub slog {
    if (open(L, ">>$logfile")) {
        print L strftime("%F %T ", localtime()), $_[0], "\n";
        print "slog: $_[0]\n" if ($rbconfig{test});
        close(L);
    }
}

sub dlog {
    if (open(L, ">>debuglog")) {
        print L strftime("%F %T ", localtime()), $_[0], "\n";
        print "dlog: $_[0]\n" if ($rbconfig{test});
        close(L);
    }
}

sub dblog($$$)
{
    return if (!$buildround);
    return if ($rbconfig{test});

    my ($cl, $key, $value) = @_;

    $dblog_sth->execute($buildround, $client{$cl}{client}, $key, $value);
}

sub command {
    my ($socket, $string) = @_;
    my $cl = $socket->fileno;
    print $socket "$string\n";
    $client{$cl}{'time'} = time();
}

sub privmessage {
    my ($cl, $string) = @_;

    my $socket = $client{$cl}{'socket'};
    print $socket "MESSAGE $string\n";
    $client{$cl}{'time'} = time();
    $client{$cl}{'expect'} = '_MESSAGE';
}

sub message {
    my ($string) = @_;

    slog "Server message: $string";
    for my $cl (&build_clients) {
        &privmessage($cl, $string);
    }
}

# return an array with the file number of all fine build clients
sub build_clients {
    my @list;
    for my $cl (keys %client) {
        if($client{$cl}{'fine'}) {
            push @list, $cl;
        }
    }
    return @list;
}

sub kill_build {
    my ($id)=@_;

    my $num = 0;

    # now kill this build on all clients still building it
    for my $cl (&build_clients) {
        # remove this build from this client
        if (defined $client{$cl}{queue}{$id} or
            defined $client{$cl}{btime}{$id})
        {
            delete $client{$cl}{queue}{$id};

            # if client started it already, cancel it!
            if (defined $client{$cl}{btime}{$id}) {
                my $rh = $client{$cl}{'socket'};

                my $took = tv_interval($client{$cl}{btime}{$id});

                slog sprintf("Cancel: build $id client %s seconds %d",
                             $client{$cl}{'client'}, $took);
                dblog($cl, "cancelled", $id);

                $wastedtime += $took;
                
                # tell client to cancel!
                command $rh, "CANCEL $id";
                $client{$cl}{'expect'}="_CANCEL";
                $num++;
                
                my $cli = $client{$cl}{'client'};
                
                unlink <"$rbconfig{uploaddir}/$cli-$id"*>;
                delete $client{$cl}{btime}{$id};
            }
            else {
                slog "Remove: build $id client $client{$cl}{client}";
                dblog($cl, "dequeued", $id);
            }
        }
    }
    return $num;
}

sub builds_in_progress {
    my $c=0;
    # count all builds that are handed out (once or more), but that aren't
    # complete yet
    for my $id (@buildids) {
        if($builds{$id}{'done'}) {
            # for safety, skip the ones that are done already
            next;
        }
        $c += $builds{$id}{'handcount'};
    }
    return $c;
}

sub builds_undone {
    my $c=0;
    # count all builds that aren't marked as done
    for my $id (@buildids) {
        if(!$builds{$id}{'done'}) {
            $c++;
        }
    }
    return $c;
}

sub readblockfile {
    if ($lastblockread + 600 < time()) {
        system("svn update --non-interactive -q blockedclients");

        if (open B, "<blockedclients") {
            %blocked = ();
            for my $line (<B>) {
                next if ($line =~ /^#/);
                chomp $line;
                my @a = split ":", $line;
                $blocked{$a[0]} = $a[1];
            }
            close B;

            for my $cl (&build_clients) {
                my $cname = \$client{$cl}{'client'};
                my $cblocked = \$client{$cl}{'blocked'};
                if (defined $blocked{$$cname}) {
                    if (not $$cblocked) {
                        slog "Adding client block for $$cname. Reason: $blocked{$$cname}.";
                    }
                    $$cblocked = 1;
                }
                else {
                    if ($$cblocked) {
                        slog "Removing client block for $$cname";
                    }
                    $$cblocked = 0;
                }
            }
        }
        $lastblockread = time();
    }
}

sub updateclient {
    my ($cl, $rev) = @_;

    my $rh = $client{$cl}{'socket'};

    # tell client to update
    command $rh, sprintf("UPDATE $rbconfig{updateurl}", $rev);
    $client{$cl}{'expect'}="_UPDATE";
    $client{$cl}{'bad'}="asked to update";

    slog sprintf("Update: rev $rev client %s",
                 $client{$cl}{'client'});

}


sub build {
    my ($fileno, $id) = @_;

    my $rh = $client{$fileno}{'socket'};
    my $cli = $client{$fileno}{'client'};
    my $rev = $buildround;
    my $args = "$id:$rev:mt:$builds{$id}{result}:$builds{$id}{upload}:$builds{$id}{cmdline}";

    # tell client to build!
    command $rh, "BUILD $args";
    dlog "BUILD $args";
    $client{$fileno}{'expect'}="_BUILD";
    $client{$fileno}{idle} = 0;

    # when is this build to be regarded as overdue?
    my $od = '';
    if ($client{$fileno}{speed}) {
        my $ulspeed = $client{$fileno}{ulspeed} || 20000;
        $builds{$id}{overdue} = time() + ($builds{$id}{score} / $client{$fileno}{speed}) + $builds{$id}{ulsize} / $ulspeed + 15;
        $od = strftime "%T", localtime $builds{$id}{'overdue'};
    }

    slog "Build: build $id rev $rev client $cli $od";
    dblog($fileno, "build", $id);

    # mark this client with what response we expect from it
    $client{$fileno}{'building'}++;

    # remember when this build started
    $client{$fileno}{'btime'}{$id} = [gettimeofday];

    # count the number of times this build is handed out
    $builds{$id}{'handcount'}++;
    $builds{$id}{'clients'}{$fileno} = 1;

    if (!$rbconfig{test}) {
        $setlastrev_sth->execute($cli, $buildround, $buildround);
        $buildclients{$cli} = 1;
    }

    # store the speed of the fastest client building
    
    if ($client{$fileno}{speed} and
        ($client{$fileno}{speed} > $builds{$id}{topspeed}))
    {
        $builds{$id}{topspeed} = $client{$fileno}{speed};
    }
}

sub _BUILD {
    my ($rh, $args) = @_;

    $client{$rh->fileno}{'expect'}="";
}

sub _MESSAGE {
    my ($rh, $args) = @_;
    $client{$rh->fileno}{'expect'}="";
}

sub _PING {
    my ($rh, $args) = @_;

    $client{$rh->fileno}{'expect'}="";
    my $t = tv_interval($client{$rh->fileno}{'ping'});
    if ($t > 2) {
        #slog "Slow _PING from $client{$rh->fileno}{client} ($t ms)";
    }
}

sub _UPDATE {
    my ($rh, $args) = @_;

    $client{$rh->fileno}{'expect'}="";
}

sub _CANCEL {
    my ($rh, $args) = @_;

    $client{$rh->fileno}{'expect'}="";
    $client{$rh->fileno}{'building'}--;
}

my $commander;
sub HELLO {
    my ($rh, $args) = @_;

    my ($version, $archlist, $auth, $cli, $cpu, $bits, $os) = split(" ", $args);

    my $fno = $rh->fileno;

    if(($version eq "commander") &&
       ($archlist eq $rbconfig{cmdpasswd}) &&
       (1 eq $rbconfig{cmdenabled}) &&
       !$commander) {
        $commander++;

        slog "Commander attached";
        command $rh, "Hello commander";

        $conn{$fno}{type} = "commander";
    }
    elsif($os eq "") {
        # send error
        slog "Bad HELLO: $args";

        command $rh, "_HELLO error";
        $client{$fno}{'bad'}="HELLO failed";
    }
    else {
        my $user;
        if($auth =~ /([^:]*):(.*)/) {
            $user = $1;
        }
        $cli .= "-$user"; # append the user name

        my $host = $client{$fno}{'host'} . ':' . $client{$fno}{'port'};

        for my $cl (&build_clients) {
            if($client{$cl}{'client'} eq "$cli") {
                slog " HELLO dupe name: $cli (host $host)";
                command $rh, "_HELLO error duplicate name!";
                $client{$fno}{'bad'}="duplicate name";
                $client{$fno}{'client'} = "$cli.dupe";
                $client{$fno}{'fine'} = 1; # include in build_clients()
                return;
            }
        }

        $client{$fno}{'client'} = $cli;
        for (split(/,/, $archlist)) {
            $client{$fno}{'archlist'}{$_} = 1;
        }
        $client{$fno}{'cpu'} = $cpu;
        $client{$fno}{'bits'} = $bits;
        $client{$fno}{'os'} = $os;
        $client{$fno}{'expect'} = ""; # no response expected yet
        $client{$fno}{'builds'} = ""; # none so far
        $client{$fno}{'bad'} = 0; # not bad!
        $client{$fno}{'blocked'} = $blocked{$cli};

        if ($version < $rbconfig{apiversion}) {
            updateclient($fno, $rbconfig{updaterevision});
            return;
        }

        my ($speed, $ulspeed) = getspeed($cli);

        # send OK
        command $rh, "_HELLO ok";

        $client{$fno}{avgspeed} = $speed;
        $client{$fno}{speed} = $speed; 
        $client{$fno}{ulspeed} = $ulspeed; 

        if ($client{$fno}{block_lift} and $client{$fno}{block_lift} < time()) {
            delete $client{$fno}{blocked};
            delete $client{$fno}{block_lift};
            slog "Block lifted for $cli";
        }

        if ($client{$fno}{blocked}) {
            slog "Blocked: client $cli blocked due to: $client{$fno}{blocked}";
            privmessage $fno, sprintf  "Hello $cli. Your build client has been temporarily blocked by the administrators due to: $client{$fno}{blocked}. $rbconfig{enablemsg}";
            return;
        }
        else {
#            my $sock = $client{$fno}{socket};
#            my($port,$iaddr) = sockaddr_in($sock);
            slog "Joined: client $cli host $host arch $archlist speed $speed";
            privmessage $fno, sprintf  "Welcome $cli. Your average build speed is $speed points/sec. Your average upload speed is %d KB/s.", $ulspeed / 1024;
            dblog($fno, "joined", "");
        }
        
        $client{$fno}{'fine'} = 1;

        if ($buildround) {
            start_next_build($fno);
        }
    }
}

sub UPLOADING {
    my ($rh, $id) = @_;
    my $cl = $rh->fileno;
    $builds{$id}{uploading} = 1;
    command $rh, "_UPLOADING";
    dblog($cl, "uploading", "$id");
    
    $client{$cl}{took}{$id} = tv_interval($client{$cl}{btime}{$id});

    # how is he doing?
    my $cli = $client{$cl}{'client'};
    my $rs;
    $client{$cl}{roundscore} += $builds{$id}{score};
    $client{$cl}{roundtime} += $client{$cl}{took}{$id};
    $client{$cl}{roundspeed} = int($client{$cl}{roundscore} / $client{$cl}{roundtime});

    if ($client{$cl}{avgspeed}) {
        $client{$cl}{relativespeed} = int($client{$cl}{speed} * 100 / $client{$cl}{avgspeed});
        $rs = $client{$cl}{relativespeed};
        #$client{$cl}{avgspeed} = $rs;
    }

    if (!$rs or $rs > 120 or $rs < 90) {
        # speed is different from what we used in calculations.
        # redo calculations.
        if (!$rs) {
            slog "$cli has speed $client{$cl}{roundspeed}";
        }
        else {
            dlog sprintf "$cli is running at $rs%% (speed %d)", $client{$cl}{roundspeed};
        }
        # reallocate for unexpectedly slow clients, not for fast
        #if (!$rs or $rs < 80) {
        #    bestfit_builds(0);
        #}
        #estimate_eta();
        #return;
    }
    #bestfit_builds(0);
}

sub GIMMEMORE {
    my ($rh, $args) = @_;

    command $rh, "_GIMMEMORE";

    my $cli = $client{$rh->fileno}{'client'};
    #slog "$cli asked for more work";

    &start_next_build($rh->fileno);
}

sub COMPLETED {
    my ($rh, $args) = @_;
    my $cl = $rh->fileno;
    my $cli = $client{$cl}{'client'};

    my ($id, $took, $ultime, $ulsize) = split(" ", $args);

    # ACK command
    command $rh, "_COMPLETED $id";

    if($builds{$id}{'done'}) {
        # This is a client saying this build is completed although it has
        # already been said to be. Most likely because we killed this build
        # already but the client didn't properly obey!
        slog "Duplicate $id completion from $cli";
        return;
    }

    if (!$buildround) {
        # round has ended, but someone wasn't killed properly
        # just ignore it
        slog "$cli completed $id after round end";
        return;
    }

    # check for build error
    if (!$rbconfig{test}) {
        my $msg = &check_log(sprintf("$rbconfig{uploaddir}/%s-%s.log", $cli, $id));
        if ($msg) {
            slog "Fatal build error: $msg. Blocking $cli.";
            privmessage $cl, "Fatal build error: $msg. You have been temporarily disabled.";
            $client{$cl}{'blocked'} = $msg;
            $client{$cl}{'block_lift'} = time() + 600; # come back in 10 minutes
            client_gone($cl);
            return;
        }
    }

    # remove this build from this client
    delete $client{$cl}{queue}{$id};
    delete $client{$cl}{btime}{$id};
    delete $builds{$id}{overdue};

    # mark this client as not building anymore
    $client{$cl}{'building'}--;

    my $uplink = 0;
    if ($ulsize and $ultime) {
        $uplink = int($ulsize / $ultime / 1024);
    }

    $took = $client{$cl}{took}{$id};

    my $speed = $builds{$id}{score} / $took;

    # mark build completed
    $builds{$id}{'handcount'}--; # one less that builds this
    $builds{$id}{'done'}=1;
    $builds{$id}{'uploading'}=0;

    my $left = 0;
    my @lefts;
    for my $b (@buildids) {
        if (!$builds{$b}{done}) {
            $left++;
            #my $cl = (keys %{$builds{$b}{clients}})[0];
            #my $spent = tv_interval($client{$cl}{btime}{$b}) * $client{$cl}{speed} if (exists $client{$cl}{speed});
            push @lefts, $b;
        }
    }

    my $timeused = time() - $buildstart;
    slog sprintf "Completed: build $id client $cli seconds %.1f uplink $uplink speed %d time $timeused left $left", $took, $speed;

    dblog($cl, "completed", sprintf("$id speed:%d uplink:$uplink", $speed));

    if ($left and $left <= 10) {
        slog sprintf "$left builds remaining: %s", join(", ", @lefts);
        message sprintf("$left build%s remaining", $left > 1 ? "s" : "");
    }

    # now kill this build on all clients still building it
    my $kills = kill_build($id);

    if (!$rbconfig{test}) {
        # log this build in the database
        &db_submit($buildround, $id, $cli, $took, $ultime, $ulsize);

        my $base=sprintf("$rbconfig{uploaddir}/%s-%s", $cli, $id);

        my $result = $builds{$id}{'result'};
        if (-f "$base-$result") {
            # if a file was uploaded, move it to storage
	    my $dest = "$rbconfig{storedir}/build-$id.zip";
            if (rename("$base-$result", $dest)) {
		slog "Moved $base-$result to $dest";
	    }
	    else {
		slog "Failed moving $base-$result to $dest: $!";
	    }
        }
        # now move over the build log
        rename("$base.log", "$rbconfig{storedir}/$buildround-$id.log");

        if (-x $rbconfig{eachcomplete}) {
            my $start = time();
            system("$rbconfig{eachcomplete} $id $cli $buildround");
            my $took = time() - $start;
            if ($took > 1) {
                slog "eachcomplete took $took seconds";
            }
        }
    }

    if (0 and $ulsize and $ultime and $client{$cl}{ulspeed}) {
        my $ulspeed = $ulsize / $ultime;
        my $rs = int(($ulspeed * 100 / $client{$cl}{ulspeed}) + 0.5);
        if ($rs > 120 or $rs < 80) {
            dlog "$cli uploads at $rs% speed";
        }
    }

    # are we finished?
    my $finished = 1;
    for my $b (@buildids) {
        if (not $builds{$b}{done}) {
            $finished = 0;
            last;
        }
    }
    if ($finished) {
        &endround();
    }
}

sub check_log
{
    my ($file) = @_;
    if (open F, "<$file") {
        my @log = <F>;
        close F;
        if (grep /No space left on device/, @log) {
            return "Out of disk space";
        }

        if (not grep /^Build Status/, @log) {
            return "Incomplete log file";
        }

        if (grep /segmentation fault/i, @log) {
            return "Compiler crashed";
        }

        if (grep /not found/i, @log) {
            return "Command not found";
        }

        if (grep /permission denied/i, @log) {
            return "Permission denied";
        }

        return "";
    }
    else {
        return "Missing log file";
    }
}

sub db_submit
{
    return unless ($rbconfig{dbuser} and $rbconfig{dbpwd});
    return if ($rbconfig{test});

    my ($revision, $id, $client, $timeused, $ultime, $ulsize) = @_;
    if ($client) {
        $submit_update_sth->execute($client, $timeused, $ultime, $ulsize, $revision, $id) or
            slog "DBI: Can't execute statement: ". $submit_update_sth->errstr;
    }
    else {
        $submit_new_sth->execute($revision, $id) or
            slog "DBI: Can't execute statement: ". $submit_new_sth->errstr;
    }
}

# commands it will accept
our %protocmd = (
    'HELLO' => 1,
    'COMPLETED' => 1,
    'UPLOADING' => 1,
    'GIMMEMORE' => 1,
    '_PING' => 1,
    '_KILL' => 1,
    '_BUILD' => 1,
    '_CANCEL' => 1,
    '_UPDATE' => 1,
    '_MESSAGE' => 1,
    );


sub parsecmd {
    no strict 'refs';
    my ($rh, $cmdstr)=@_;
    
    if($cmdstr =~ /^([A-Z_]*) *(.*)/) {
        my $func = $1;
        my $rest = $2;
        chomp $rest;
        if($protocmd{$func}) {
            &$func($rh, $rest);
            #dlog "$client{$rh}{client} said $rest";
        }
        else {
            chomp $cmdstr;
            slog "Unknown input: $cmdstr";
        }
    }
}

# $a and $b are buildids
sub fastclient {
    # done builds are, naturally, last
    my $s = $builds{$b}{'done'} <=> $builds{$a}{'done'};

    if (!$s) {
        # delay handing out builds that are being uploaded right now
        $s = $builds{$b}{'uploading'} <=> $builds{$a}{'uploading'};
    }

    if (!$s) {
        # 'handcount' is the number of times the build has been handed out
        # to a client. Get the lowest one first.
        $s = $builds{$b}{'handcount'} <=> $builds{$a}{'handcount'};
    }

    if (!$s) {
        # hand out upload builds before no-upload
        $s = $builds{$a}{'upload'} cmp $builds{$b}{'upload'};
    }

    if(!$s) {
        # if the same handcount, take score into account
        $s = $builds{$a}{'score'} <=> $builds{$b}{'score'};
    }
    return $s;
}

# $a and $b are buildids
sub slowclient {
    # done builds are, naturally, last
    my $s = $builds{$b}{'done'} <=> $builds{$a}{'done'};

    if (!$s) {
        # delay handing out builds that are being uploaded right now
        $s = $builds{$b}{'uploading'} <=> $builds{$a}{'uploading'};
    }

    if (!$s) {
        # 'handcount' is the number of times the build has been handed out
        # to a client. Get the lowest one first.
        $s = $builds{$b}{'handcount'} <=> $builds{$a}{'handcount'};
    }

    if(!$s) {
        # if the same handcount, take score into account
        $s = $builds{$b}{'score'} <=> $builds{$a}{'score'};
    }
    return $s;
}

# $a and $b are file numbers
sub sortclients {
    return $client{$b}{'speed'} <=> $client{$a}{'speed'};
}

sub resetbuildround {
    # mark all done builds as not done, not handed out
    for my $id (@buildids) {
        $builds{$id}{'done'}=0;
        $builds{$id}{'handcount'}=0;
    }
}

sub startround {
    my ($rev) = @_;
    # start a build round

    &getbuilds();

    # no uploads during testing
    if (0 and $rbconfig{test}) {
        for my $id (@buildids) {
            $builds{$id}{upload} = 0;
        }
    }

    $buildround=$rev;
    $buildstart=time();
    $wastedtime = 0;
    $speculative = 0;

    resetbuildround();

    my $num_clients = scalar &build_clients;
    my $num_builds = scalar @buildids;

    slog "New round: $num_clients clients $num_builds builds rev $rev";
    if (!$num_clients) {
        slog "No clients connected. Round aborted.";
        return;
    }
    if (!$num_builds) {
        slog "No builds configured. Round aborted.";
        return;
    }

    # disable targets that no client can build
    for my $b (@buildids) {
        my $found = 0;
        for my $cl (&build_clients) {
            if (&client_can_build($cl, $b)) {
                $found = 1;
                last;
            }
        }
        if (not $found) {
            slog "Nobody can build $b. Disabling target.";
            $builds{$b}{done} = 1;
        }
    }
    if (!builds_undone()) {
        slog "No client can build any target! Round aborted.";
        return;
    }

    message sprintf "New build round started. Revision $rev, $num_builds builds, $num_clients clients.";

    if (!$rbconfig{test}) {

        # run housekeeping script
        if (-x $rbconfig{roundstart}) {
            my $start = time();
            system("$rbconfig{roundstart} $buildround");
            my $took = time() - $start;
            if ($took > 1) {
                slog "rbconfig{roundstart} took $took seconds";
            }
        }

        my $sth = $db->prepare("DELETE FROM log WHERE revision=?") or 
            slog "DBI: Can't prepare statement: ". $db->errstr;
        $sth->execute($buildround);

        # fill db with builds to be done
        for my $id (@buildids) {
            &db_submit($buildround, $id);
        }
    }

    %buildclients = ();
    
    # calculate total connected farm speed
    my $totspeed = 0;
    for (&build_clients) {
        $totspeed += $client{$_}{speed};
    }

    if ($totspeed) {
        bestfit_builds();
    }
    else {
        evenspread_builds();
    }

    if (1) {
        # start all clients who aren't currently running,
        # those with allocated builds first
        for my $c (sort { $client{$b}{points} <=> $client{$a}{points} }
                   &build_clients)
        {
            if (!scalar keys %{$client{$c}{btime}}) {
                &start_next_build($c);
            }
        }
    }
}

sub endround {
    # end of a build round

    if(!$buildround) {
        # avoid accidentally doing this twice
        return;
    }

    my $inp = builds_in_progress();
    my $took = time() - $buildstart;
    my $kills = 0;

    # kill all still handed out builds
    for my $id (@buildids) {
        if($builds{$id}{'handcount'}) {
            # find all clients building this and cancel
            $kills += kill_build($id);
            $builds{$id}{'handcount'}=0;
        }
    }
    slog "End of round $buildround: skipped $inp seconds $took wasted $wastedtime";

    message sprintf "Build round completed after $took seconds.";

    resetbuildround();

    # clear upload dir
    rmtree( $rbconfig{uploaddir}, {keep_root => 1} );

    if(!$rbconfig{test} and -x $rbconfig{roundend}) {
        my $rounds_sth = $db->prepare("INSERT INTO rounds (revision, took, clients) VALUES (?,?,?) ON DUPLICATE KEY UPDATE took=?,clients=?") or 
            slog "DBI: Can't prepare statement: ". $db->errstr;
        $rounds_sth->execute($buildround,
                             $took, scalar keys %buildclients,
                             $took, scalar keys %buildclients);

        my $start = time();
        system("$rbconfig{roundend} $buildround");
        my $rbtook = time() - $start;
        if ($rbtook > 1) {
            slog "roundend took $rbtook seconds";
        }
    }
    $buildround=0;

    # recalculate speed values for all clients
    for my $cl (&build_clients) {
        my ($speed, $ulspeed) = getspeed($client{$cl}{client}, $buildround);
        $client{$cl}{avgspeed} = $speed;
        $client{$cl}{speed} = $speed; 
        $client{$cl}{ulspeed} = $ulspeed; 
    }

    if ($nextround) {
        &startround($nextround);
        $nextround = 0;
    }
}

sub checkclients {
    my $check = time() - 10;

    for my $cl (&build_clients) {

        if($client{$cl}{'expect'} eq "_PING") {
            # if this is already waiting for a ping, we take different
            # precautions and allow for some PING response time
            my $pcheck = time() - 30;
            if($client{$cl}{'time'} < $pcheck) {
                my $t = time() - $client{$cl}{'time'};
                # no ping response either, disconnect
                $client{$cl}{'bad'}="ping timeout (${t}s)";
            }
            next;
        }

        if($client{$cl}{'time'} < $check) {
            # too old, speak up!
            my $rh = $client{$cl}{'socket'};
            my $exp = $client{$cl}{'expect'};
            my $t = time() - $client{$cl}{'time'};
            if($exp) {
                #slog "Alert: Waiting ${t}s for $exp from client $client{$cl}{client}!";
            }
            command $rh, "PING";
            $client{$cl}{'ping'}=[gettimeofday];
            $client{$cl}{'expect'}="_PING";
        }
    }
}

sub client_can_build {
    my ($cl, $id)=@_;

    # figure out the arch of this build
    my $arch = $builds{$id}{'arch'};

    # see if this arch is among the supported archs for this client
    if(defined $client{$cl}{'archlist'}{$arch}) {
        # yes it can build
        return 1;
    }
    
    return 0; # no cannot build
}

sub client_gone {
    my ($cl) = @_;

    # check which builds this client had queued, and free them up
    for my $id (keys %{$client{$cl}{queue}}) {
        $builds{$id}{'assigned'} = 0;
        slog "$client{$cl}{client} abandoned build $id";
        dblog($cl, "abandoned", $id);
        $abandoned_builds += 1;
    }

    # check which builds this client had started, and decrease handcount
    for my $id (keys %{$client{$cl}{btime}}) {
        $builds{$id}{handcount}--;
        delete $builds{$id}{'clients'}{$cl};
        dblog($cl, "abandoned", $id);
    }

    # are any clients left?
    if ($buildround and (scalar &build_clients) == 0) {
        slog "Ending round due to lack of clients";
        endround();
    }
}

sub bigsort
{
    my ($usecount) = @_;

    # done builds are, obviously, last
    my $s = $builds{$a}{'done'} <=> $builds{$b}{'done'};

    if (!$s) {
        # delay handing out builds that are being uploaded right now
        $s = $builds{$a}{'uploading'} <=> $builds{$b}{'uploading'};
    }
    
    if ($usecount and !$s) {
        # 'handcount' is the number of times the build has been handed out
        # to a client. Get the lowest one first.
        $s = $builds{$a}{'handcount'} <=> $builds{$b}{'handcount'};
    }

    if (!$s) {
        # do few-client builds before many-client builds
        $s = $builds{$a}{'canbuild'} <=> $builds{$b}{'canbuild'};
    }

    if (!$s) {
        # do upload builds before no-upload builds
        $s = $builds{$a}{'upload'} cmp $builds{$b}{'upload'};
    }

    if (!$s) {
        # do heavy builds before light builds
        $s = $builds{$b}{score} <=> $builds{$a}{score};
    }

    return $s;
}

sub bigbuilds
{
    return sort {bigsort(1)} @buildids;
}

sub smallsort
{
    # done builds are, obviously, last
    my $s = $builds{$a}{'done'} <=> $builds{$b}{'done'};

    if (!$s) {
        # delay handing out builds that are being uploaded right now
        $s = $builds{$a}{'uploading'} <=> $builds{$b}{'uploading'};
    }
    
    if (!$s) {
        # 'handcount' is the number of times the build has been handed out
        # to a client. Get the lowest one first.
        $s = $builds{$a}{'handcount'} <=> $builds{$b}{'handcount'};
    }

    if (!$s) {
        # do no-upload builds before upload builds
        my $s = $builds{$b}{'upload'} cmp $builds{$a}{'upload'};
    }

    if (!$s) {
        # do light builds before heavy builds
        $s = $builds{$a}{score} <=> $builds{$b}{score};
    }

    return $s;
}

sub smallbuilds
{
    return sort smallsort @buildids;
}

sub client_eta($)
{
    my ($c) = @_;

    for my $b (keys %{$client{$c}{queue}}) {
        return 0 if ($builds{$b}{uploading});
        if ($client{$c}{btime}{$b} and $client{$c}{speed}) {
            my $expected = $builds{$b}{score} / $client{$c}{speed};
            my $spent = tv_interval($client{$c}{btime}{$b});
            if ($spent > $expected) {
                return 0;
            }
            return ($expected - $spent, $b);
        }
    }
    return 0;
}

sub evenspread_builds 
{
    # First time ever == no client speed ratings.
    # Abandon all ambitions of intelligence and just smear the builds
    # evenly across all clients.
    
    for my $cl (&build_clients) {
        $client{$cl}{points} = 0;
    }

    for my $build (@buildids) {
        for my $cl (sort { $client{$a}{points} <=> $client{$b}{points} }
                    &build_clients)
        {
            if (client_can_build($cl, $build)) {
                $client{$cl}{queue}{$build} = 1;
                $client{$cl}{points} += $builds{$build}{score};
                $builds{$build}{assigned} = 1;
                last;
            }
        }
    }
}


my $firsttime = 0;
sub bestfit_builds
{
    my %deduct;
    my %todo;
    my $totaldeduct;

    dlog "-----------";

    # calculate total work to be done
    my $totwork = 0;
    for my $b (@buildids) {
        if (!$builds{$b}{done} and !$builds{$b}{uploading}) {
            $totwork += $builds{$b}{score};
        }
    }

    # how many clients for each build?
    for my $b (@buildids) {
        $builds{$b}{canbuild} = 0;
        for my $c (&build_clients) {
            if (client_can_build($c, $b)) {
                $builds{$b}{canbuild} += 1;
            }
        }
    }

    my $totspeed = 0;
    for (&build_clients) {
        $totspeed += $client{$_}{speed};

        if ($client{$_}{block_lift} and $client{$_}{block_lift} < time()) {
            delete $client{$_}{blocked};
            delete $client{$_}{block_lift};
            my $cli = $client{$_}{client};
            slog "Block lifted for $cli";
        }
    }
    slog sprintf "Total work: %d points", $totwork;
    slog sprintf "Total speed: %d points/sec (%d clients)", $totspeed, scalar &build_clients;

    my $idealtime = int(($totwork / $totspeed) + 0.5);
    slog "Ideal time: $idealtime seconds";

    my $margin = 5;

  tryagain:
    my $totleft = 0;

    # remove assignments
    for my $b (@buildids) {
        $builds{$b}{assigned} = 0;
    }

    my @debug = ();
    $estimated_time = int($totwork / $totspeed + 0.5) + $margin;
    my $diff = 0;
    if ($firsttime) {
        $diff = $estimated_time - $firsttime - (time - $buildstart);
    }
    slog sprintf "Realistic time with $margin margin: $estimated_time seconds (%+d)", $diff;
    dlog "----- margin $margin --- estimated_time $estimated_time --------";
    
    # loop through all clients, slowest first
    # give each client as much work as it can do in the estimated time
    for my $c (sort {$client{$a}{speed} <=> $client{$b}{speed}} &build_clients)
    {
        next if ($client{$c}{blocked});
        
        $client{$c}{queue} = ();

        my $speed = $client{$c}{speed};
        my $maxtime = $estimated_time;
        $client{$c}{timeused} = 0;
        $client{$c}{points} = 0;

        my $sort_order;
        if ($speed > 0) {
            # we know how fast the client usually is.
            # give it as much work as it can do
            $sort_order = \&bigbuilds;
        }
        else {
            # if we don't know how fast the client is,
            # give it something light and see how fast it is
            $sort_order = \&smallbuilds;
            $maxtime = 99999;
        }

        my $lastultime = 0;
        my $ulspeed = $client{$c}{ulspeed} || 20000; # assume 20 KB/s uplink

        for my $b (&$sort_order)
        {
            next if ($builds{$b}{assigned});
            
            my $buildtime = 0;
            if ($speed) {
                $buildtime = $builds{$b}{score} / $speed;
            }

            # no single build must use more than 75% of total time
            # or it will likely be "overtaken" by other clients
            next if ($buildtime > $estimated_time * 3 / 4);
            
            my $ultime = $builds{$b}{ulsize} / $ulspeed;
            my $endtime = $client{$c}{timeused} + $buildtime + $ultime - $lastultime;
            
            if (client_can_build($c, $b) and ($endtime < $maxtime))
            {
                $client{$c}{queue}{$b} = $buildtime || 1;
                $client{$c}{ultime}{$b} = $ultime;
                $client{$c}{timeused} += $buildtime + $ultime - $lastultime;
                $client{$c}{points} += $builds{$b}{score};
                $builds{$b}{assigned} = 1;
                $lastultime = $ultime;

                # speed-less clients only do one build
                last if (!$speed);
            }
        }
        $totleft += int($maxtime - $client{$c}{timeused});
    }

    # any unassigned builds?
    for my $b (@buildids) {
        if (!$builds{$b}{assigned} and !$builds{$b}{done}) {
            # increase the margin and try again
            $margin += 5;
            dlog "*** $b unassigned, trying again";
            #sleep 1;
            goto tryagain;
        }
    }

    for my $c (sort {$client{$a}{speed} <=> $client{$b}{speed}} &build_clients) {
        my @blist;
        my @dlist;
        my $bcount = 0;
        my $ulspeed = $client{$c}{ulspeed} || 20000; # assume 20 KB/s uplink
        for my $b (sort bigsort keys %{$client{$c}{queue}}) {
            my $btime = 0;
            if ($client{$c}{speed}) {
                $btime = $builds{$b}{score} / $client{$c}{speed};
            }
            push @blist, sprintf("$b:%d:%d",
                                 $btime,
                                 $builds{$b}{ulsize} / $ulspeed);
            $bcount ++;
        }
        my $buildlist = join ", ", @blist;

        push @debug, sprintf("%-24s (b%3d,u%3d) does $bcount %.1f sec $buildlist",
                             $client{$c}{client},
                             $client{$c}{speed}, $ulspeed / 1024,
                             $client{$c}{timeused});
    }


    for my $cl (&build_clients) {
        my $num = 1;
        my $speed = $client{$cl}{speed};
        for my $b (sort bigsort keys %{$client{$cl}{queue}}) {
            my $buildtime = int($client{$cl}{queue}{$b} + 0.5);
            my $ultime = int($client{$cl}{ultime}{$b} + 0.5);
            dblog($cl, "queued", "$num:$b:$buildtime:$ultime");
            $num++;
        }
    }

    for (@debug) {
        dlog $_;
    }

    $firsttime = $estimated_time if (!$firsttime);

    my $bcount = scalar @buildids;
    dlog "$bcount builds in $estimated_time seconds. $totleft seconds unused";
}

sub start_next_build($)
{
    my ($cl) = @_;

    return if (!$buildround);
    return if ($client{$cl}{blocked});

    my $cli = $client{$cl}{client};

    # start next in queue
    for my $id (sort {bigsort(0)} keys %{$client{$cl}{queue}})
    {
        if (!$builds{$id}{done} and !$builds{$id}{uploading})
        {
            &build($cl, $id);
            return;
        }
    }

    # queue is empty. how can I help?

    # any abandoned builds I can do?
    if ($abandoned_builds)
    {
        for my $id (&bigbuilds) {
            if (client_can_build($cl, $id) and !$builds{$id}{assigned}) {
                $client{$cl}{queue}{$id} = 1;
                $builds{$id}{assigned} = 1;
                $abandoned_builds -= 1;
                #dlog "$cli does abandoned $id";
                &build($cl, $id);
                return;
            }
        }
    }
    
    if (1) {
        # help with other builds, speculatively
        for my $id (&smallbuilds) {
            next if (!client_can_build($cl, $id));
            next if (defined $client{$cl}{btime}{$id});
            # don't start any build that would take >66% of round time
            if ($estimated_time) {
                next if ($client{$cl}{roundspeed} and ($builds{$id}{score} / $client{$cl}{roundspeed} > $estimated_time * 2 / 3));
            }
            if (!$builds{$id}{done}) {
                if ($builds{$id}{handcount} == 0) {
                    #dlog "$cli does unstarted $id";
                }
                else {
                    if (!$speculative) {
                        message "Speculative building started";
                        $speculative = 1;
                    }

                    # don't start building this if someone faster
                    # is already building it
                    #next if ($builds{$id}{topspeed} > $client{$cl}{speed})
                }
                &build($cl, $id);
                return;
            }
        }
    }
        
    # there's nothing for me to do!
    $client{$cl}{idle} = 1;
    slog "Client $client{$cl}{client} is idle.";

    my $idle_clients = 0;
    for my $c (&build_clients) {
        if ($client{$c}{idle}) {
            $idle_clients++;
        }
    }

    dlog sprintf "%d / %d clients are idle.", $idle_clients, scalar &build_clients;
}

sub assign_abandoned_builds
{
    if ($abandoned_builds and $idle_clients) {
        for my $id (&bigbuilds) {
            if (!$builds{$id}{assigned}) {
                for my $c (sort {$client{$b}{speed} <=> $client{$a}{speed}} &build_clients) {
                    if (!scalar keys %{$client{$c}{queue}}) {
                        $client{$c}{queue}{$id} = $builds{$id}{score};
                        $abandoned_builds -= 1;
                        $idle_clients -= 1;
                        &start_next_build($c);
                    }
                }
            }
        }
    }
}

sub assign_overdue_builds
{
    my $now = time();
    for my $id (sort {$builds{$b}{overdue} <=> $builds{$a}{overdue}} @buildids)
    {
        last if (not $builds{$id}{overdue});

        if ($builds{$id}{overdue} <= $now) {
            # we have an overdue build
            # give it to the fastest idle client

            for my $cl (sort {$client{$b}{roundspeed} <=> $client{$a}{roundspeed}} &build_clients) {
                if (not keys %{$client{$cl}{btime}}) {
                    slog "Overdue: $client{$cl}{client} ($client{$cl}{speed}) starts overdue build $id";
                    &build($cl, $id);
                    last;
                }
            }
        }
    }
}


sub estimate_eta
{
    my %buildhost;

    for my $cl (build_clients()) {
        my $cspeed = $client{$cl}{speed};
        next if (not $cspeed);

        my ($t, $id) = client_eta($cl);
        my $eta = int(time + $t);
        if ($t) {
            if (not defined $buildtimes{$id} or
                $buildtimes{$id} > $eta)
            {
                $buildtimes{$id} = $eta;
                $buildhost{$id} = $client{$cl}{client};
            }
        }
        
        for $id (sort {$builds{$b}{score} <=> $builds{$a}{score}}
                 keys %{$client{$cl}{queue}})
        {
            $eta += int($builds{$id}{score} / $cspeed);
            if (not defined $buildtimes{$id} or
                $buildtimes{$id} > $eta)
            {
                $buildtimes{$id} = $eta;
            }
        }
    }

    my @slist = sort {$buildtimes{$b} <=> $buildtimes{$a}} @buildids;
    my $last = $slist[0];
    dlog sprintf("Last build ($last:$buildhost{$last}) is expected to complete in %d seconds",
                 $buildtimes{$last} - time);
}

my $stat;

# Control commands:
#
# BUILD [rev] - start a build immediately, or fail if one is already in
# progress
#

sub control {
    my ($rh, $cmd) = @_;
    chomp $cmd;
    slog "Commander says: $cmd";

    if($cmd =~ /^BUILD (\w+)/) {
        if(!$buildround) {
            &startround($1);
        }
        else {
            $nextround = $1;
        }
    }
    elsif ($cmd =~ /^UPDATE (.*?) (\d+)/) {
        for my $cl (&build_clients) {
            if ($client{$cl}{client} eq "$1") {
                &update_client($cl, $2);
            }
        }
    }
}

readconfig();
getbuilds("builds");
db_connect();
db_prepare();

# Master socket for receiving new connections
my $server = new IO::Socket::INET(
    LocalPort => $rbconfig{portnum},
    Proto => "tcp",
    Listen => 20,
    Reuse => 1)
or die "socket: $!\n";

# Add the master socket to select mask
my $read_set = new IO::Select();
$read_set->add($server);
$conn{$server->fileno} = { type => 'master' };

readblockfile();

print "Server starts. See 'logfile'.\n";

slog "Server starts";
dlog "=================== Server starts ===================";

# Main loop active until ^C pressed
my $alldone = 0;
$SIG{KILL} = sub { slog "Killed"; exit; };
$SIG{INT} = sub { slog "Received interrupt"; $alldone = 1; };
$SIG{PIPE} = sub {
 slog "SIGPIPE";
 };
$SIG{__DIE__} = sub { slog(sprintf("Perl error: %s", @_)); };
while(not $alldone) {
    my @handles = sort map $_->fileno, $read_set->handles;
    my ($rh_set, $timeleft) =
        IO::Select->select($read_set, undef, undef, 1);

    foreach my $rh (@$rh_set) {
        if (not exists $conn{$rh->fileno}) {
            slog "Fatal: Untracked rh!";
            die "untracked rh";
        }
        my $type = $conn{$rh->fileno}{type};

        if ($type eq 'master') {
            my $new = $rh->accept or die;
            $read_set->add($new);
            $conn{$new->fileno} = { type => 'rbclient' };
            $new->blocking(0) or die "blocking: $!";
            $client{$new->fileno}{'socket'} = $new;
            my $peeraddr = $new->peeraddr;
            my $hostinfo = gethostbyaddr($peeraddr);
            if ($hostinfo) {
                $client{$new->fileno}{'host'} = $hostinfo->name;
            }
            else {
                $client{$new->fileno}{'host'} = $new->peerhost;
            }
            $client{$new->fileno}{'port'} = $new->peerport;
        }
        else {
            my $data;
            my $fileno = $rh->fileno;
            my $len = $rh->read($data, 512);

            if ($len) {
                my $cmd = \$client{$fileno}{'cmd'};
                $$cmd .= $data;
                while (1) {
                    my $pos = index($$cmd, "\n");
                    last if ($pos == -1);
                    if ($type eq 'commander') {
                        &control($rh, $$cmd);
                    }
                    else {
                        &parsecmd($rh, $$cmd);
                        $type = $conn{$rh->fileno}{type};
                    }
                    $$cmd = substr($$cmd, $pos+1);
                }
            }
            else {
                if ($type eq 'commander') {
                    slog "Commander left";                
                    delete $conn{$fileno};
                    $read_set->remove($rh);
                    $rh->close;
                    $commander=0;
                }
                else {
                    $client{$fileno}{fine} = 1;
                    
                    if (not $client{$fileno}{'bad'}) {
                        $client{$fileno}{'bad'}="connection lost";
                    }
                }
            }
        }
    }

    # loop over the clients and close the bad ones
    foreach my $cl (&build_clients) {

        my $err = $client{$cl}{'bad'};
        if($err) {
            my $cli = $client{$cl}{'client'};

            slog "Disconnect: client $cli reason $err";
            dblog($cl, "disconnect", $err);
            $client{$cl}{fine} = 0;
            client_gone($cl);
            my $rh = $client{$cl}{'socket'};
            if ($rh) {
                $read_set->remove($rh);
                $rh->close;
            }
            else {
                slog "!!! No rh to delete for client $cli";
            }
            delete $client{$cl};
            delete $conn{$cl};

            # we lost a client, re-allocate builds
            #if ($buildround) {
            #    &bestfit_builds(0);
            #}
        }
    }

    #assign_overdue_builds();

    checkclients();
    readblockfile();
}
slog "exiting.\n";
