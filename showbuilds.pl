#!/usr/bin/perl
use POSIX 'strftime';
require "rbmaster.pm";

$ENV{'TZ'} = "UTC";

my $buildrev = $ARGV[0];
my $showallbuilds = 0;

if ($buildrev == 1) {
    $buildrev = 0;
    $showallbuilds = 1;
}

my @b;
my %rounds;
my %round;
my %dir; # hash per type for build dir

# number of rounds in the output table
my $maxrounds = 20;

sub getdata {
    db_connect();
    my $maxrows = $maxrounds * scalar keys %builds;
    my $sth = $db->prepare("SELECT revision,id,errors,warnings,client,timeused FROM builds ORDER BY revision DESC limit $maxrows") or
        warn "DBI: Can't prepare statement: ". $db->errstr;
    my $rows = $sth->execute();
    if ($rows) {
        while (my ($rev,$id,$errors,$warnings,$client,$time) = $sth->fetchrow_array()) {
            $compiles{$rev}{$id}{errors} = $errors;
            $compiles{$rev}{$id}{warnings} = $warnings;
            if ($errors>0 or $warnings>0) {
                $alltypes{$id} = 1;
            }
            $compiles{$rev}{$id}{client} = $client;
            $clients{$rev}{$client} = 1;
            $compiles{$rev}{$id}{time} = $time;
            $alltypes{$id} = 1 if ($showallbuilds);
            if (scalar keys %compiles > $maxrounds) {
                delete $compiles{$rev};
                last;
            }
        }
    }

    $csth = $db->prepare("SELECT revision,clients,took FROM rounds ORDER BY revision DESC limit $maxrounds");
    my $rows = $csth->execute();
    if ($rows) {
        while (my ($rev, $clients,$took) = $csth->fetchrow_array()) {
            $round{$rev}{clients} = $clients;
            $round{$rev}{time} = $took;
        }
    }
}

&getbuilds();
&getdata();

foreach my $b (keys %builds) {
    my $text = $builds{$b}{name};
    $text =~ s/FM Recorder/FM Rec/;
    $text =~ s/Debug/Dbg/;
    $text =~ s/Normal//;
    $text =~ s/Simulator/Sim/;
    $text =~ s/iriver *//i;
    $text =~ s/Archos *//i;
    $text =~ s/ - $//;
    $text =~ s/Win32/Win/;
    $text =~ s/- +-/-/g;
    $text =~ s/Grayscale/Gray/;
    $text =~ s/Sim - Win/Sim32/;
    $text =~ s/Toshiba *//i;
    $text =~ s/SanDisk *//i;
    $text =~ s/Olympus *//i;
    $text =~ s/Creative *//i;
    $text =~ s/Philips *//i;
    $text =~ s/Zen Vision M/ZVM/i;
    $text =~ s/Samsung/Smsg/i;
    $builds{$b}{sortkey} = uc $text;
}

print "<table class=\"buildstatus\" cellspacing=\"1\" cellpadding=\"0\"><tr>";
print "<th>rev / time</th>";
print "<th>score</th>";
print "<th>time</th>";
foreach $t (sort {$builds{$a}{sortkey} cmp $builds{$b}{sortkey}} keys %alltypes) {

    my ($a1, $a2);
    if (-f "data/rockbox-$t.zip") {
        $a1 = "<a href='data/rockbox-$t.zip' >";
        $a2 = "</a>";
    }
    print"<th>$a1<img border=0 width='16' height='130' title='$builds{$t}{name}' src=\"http://build.rockbox.org/titles/$t.png\">$a2</th>\n";
}
print "</tr>\n";

#######################
my $numbuilds = scalar(keys %alltypes);
my $js;
if($buildrev) {
    my $rounds_sth = $db->prepare("SELECT took FROM rounds ORDER BY revision DESC LIMIT 5") or 
        die "DBI: Can't prepare statement: ". $db->errstr;
    my $rows = $rounds_sth->execute();
    my $prevtime = 0;
    if ($rows) {
        while (my ($took) = $rounds_sth->fetchrow_array()) {
            $prevtime += $took;
        }
        $prevtime /= $rows;
    }

    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday) =
        gmtime(time);

    my $text ="Build in progress";
    if($prevtime) {
        my ($dsec,$dmin,$dhour,$dmday,$dmon,$dyear,$dwday,$dyday) =
            gmtime(time()+$prevtime);
        $text = sprintf("Build <span id=\"countdown_text\">expected to complete around %02d:%02d:%02d (in %dmins %dsecs)</span></a>",
                        $dhour, $dmin, $dsec,
                        $prevtime/60, $prevtime%60);
        $js = sprintf("<script type=\"text/javascript\">countdown_refresh(%d,%d,%d,%d,%d,%d);</script>",
                          $dyear+1900, $dmon, $dmday,
                          $dhour, $dmin, $dsec);
    }

    printf("<tr><td colspan=3><a class=\"bstamp\" href=\"http://svn.rockbox.org/viewvc.cgi?view=rev;revision=$buildrev\">$buildrev</a> (in progress)</td><td class=\"building\" colspan=\"%d\">$text</td></tr>\n",
           $numbuilds);
}
#################

my $count=0;
for my $rev (sort {$b <=> $a} keys %compiles) {
    my @types = keys %{$compiles{$rev}};

    my $time = (stat("data/$rev-clients.html"))[9];
    my $timestring = strftime("%H:%M", localtime $time);

    print "<tr align=center>\n";

    my $chlink = "<a class=\"bstamp\" href=\"http://svn.rockbox.org/viewvc.cgi?view=rev;revision=$rev\">$rev</a> $timestring";

    my $score=0;
    print "<td nowrap>$chlink</td>\n";

    my %servs;
    my %bt;

    my @tds;

    if (scalar keys %alltypes == 0 and !$count) {
        my $bcount = scalar @buildids;
        push @tds, "<td class=buildok style='padding: 5px' rowspan=20>All $bcount builds are OK</td>";
    }

    for my $type (sort {$builds{$a}{sortkey} cmp $builds{$b}{sortkey}} keys %alltypes) {

        if (not defined $compiles{$rev}{$type}{client}) {
            push @tds, "<td>&nbsp;</td>\n";
            next;
        }

        my $ok = 1;
        my $text = "0";
        my $class = "buildok";

        my $b = \%{$compiles{$rev}{$type}};

        if ($$b{errors}) {
            $text=$$b{errors};
            $score += ($$b{errors} * 10) + $$b{warnings};
            if($$b{warnings}) {
                $text .= "<br>(".$$b{warnings}.")";
            }
            $class="buildfail";
        }
        elsif ($$b{warnings}) {
            $class="buildwarn";
            $text = $$b{warnings};
            $score += $$b{warnings};
        }
        
        push @tds, sprintf("<td class=\"%s\"><a class=\"blink\" href=\"shownewlog.cgi?rev=%s;type=%s\" title=\"Built by %s in %d secs\">%s</a></td>\n",
                           $class,
                           $rev, $type,
                           $$b{client}, $$b{time},
                           $text);
    }
    printf "<td>%d</td>", $score;
    printf("<td><a href=\"data/$rev-clients.html\">%d:%02d</a></td>",
           $round{$rev}{time} / 60, $round{$rev}{time} % 60);
    print @tds;
    print "</tr>\n";
    $count++;
}

printf "</table>\n";

print $js;
