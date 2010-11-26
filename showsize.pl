#!/usr/bin/perl
require "rbmaster.pm";

my $dir="data";

opendir(DIR, $dir) || die "can't opendir $dir: $!";
my @logs = sort grep { /.sizes$/ && -f "$dir/$_" } readdir(DIR);
closedir DIR;

my %title;
my $rounds;
my %lines;

my %this;
my %delta;

getbuilds();

sub singlefile {
    my($file)=@_;
    my @o;
    my %single;
    my $totaldelta=0;
    my $models=0;

    open(F, "<$file");
    while(<F>) {
	if(/^([^ :]*) *: *(\d+) *(\d*)/) {
	    my ($name, $size, $ram)=($1, $2, $3);
	    $title{$name} += $size;
	    my $delta = 0;
            my $ramdelta = 0;
            my $t;
            $ram += 0;
            my $title;

	    if($thisram{$name} && $ram) {
		$ramdelta = $ram - $thisram{$name};
		my $cl="";
		if($ramdelta > 16) {
		    $cl = "buildfail";
		}
		elsif($ramdelta < -16) {
		    $cl="buildok";
		} 
		$t = "<td class=\"$cl\">$ramdelta</td>";
	    }
	    else {
		$t = "<td>-</td>";
	    }
            $title="\nRAM: $ramdelta/$ram bytes";
            $singleram{$1}=$t;

            my $t2;

	    if($this{$name} && $size) {
		$delta = $size - $this{$name};
            }

            my $delta2 = ($delta + $ramdelta)/2;

            my $cl="";
            if($delta2 > 16) {
                $cl = "buildfail";
            }
            elsif($delta2 < -16) {
                $cl="buildok";
            }

            $t2 ="<td class=\"$cl\" title=\"Bin: $delta/$size bytes $title\">${delta2}</td>";

            $single{$1} = $t2;
	    $totaldelta += $delta2;
	    if($size) {
		$this{$name}=$size;
	    }
	    if($ram) {
		$thisram{$name}=$ram;
	    }
	    $models++;
	} 
    }
    close(F);

    for my $t (sort {$builds{$a}{name} cmp $builds{$b}{name}} keys %title) {
        my $tx = $single{$t};
        if(!$tx) {
            $tx="<td>&nbsp;</td>";
        }
	$lines{$file} .= $tx;
    }
    
    my $cl="";
    if($models > 0) {
	$totaldelta = sprintf("%d", $totaldelta/$models);
    }
    if($totaldelta > 16) {
	$cl = "buildfail";
    }
    elsif($totaldelta < -16) {
	$cl="buildok";
    } 
    $lines{$file} .= "<td class=\"$cl\">$totaldelta</td>";

}


foreach my $l (@logs) {
    if( -s "$dir/$l") {
	singlefile("$dir/$l");
	$rounds++;
    }
}

print <<MOO

<p> File size deltas of the binary main Rockbox images during the most recent
 commits. Hover over the delta to get the exact file size in bytes.

MOO
;
print "<table class=\"buildstatus\" cellspacing=\"1\" cellpadding=\"2\"><tr><th>Revision</th>\n";
for my $t (sort {$builds{$a}{name} cmp $builds{$b}{name}} keys %title) {
    print "<td><img width='16' height='130' alt=\"$t\" src=\"/titles/$t.png\"></td>\n";
}
print "<th>Delta</th>\n";
print "</tr>\n";

my $c;
foreach my $l (reverse sort @logs) {
    if($lines{"$dir/$l"}) {
        $l =~ /^(\d+).sizes$/;
        my $rev = $1;
        $b = "<a class=\"bstamp\" href=\"http://svn.rockbox.org/viewvc.cgi?view=rev;revision=$rev\">$rev</a>";

	print "<tr><td nowrap>$b</td>";
	print $lines{"$dir/$l"}."\n";
	print "<td><a href=\"/data/$l\">log</a></td>";
	print "</tr>\n";

	if($c++ > 18) {
	    last;
	}
    }
}
print "</table>";

