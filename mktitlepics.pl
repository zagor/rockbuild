#!/usr/bin/perl

my $dir = "titles";

my %builds;

# copy from rbmaster.pl, could be made a .pm
sub getbuilds {
    my ($filename)=@_;
    open(F, "<$filename");
    while(<F>) {
        # sdl:nozip:recordersim:Recorder - Simulator:rockboxui:--target=recorder,--ram=2,--type=s
        if($_ =~ /([^:]*):([^:]*):([^:]*):([^:]*):([^:]*):(.*)/) {
            my ($arch, $zip, $id, $name, $file, $confopts) =
                ($1, $2, $3, $4, $5, $6);
            $builds{$id}{'arch'}=$arch;
            $builds{$id}{'zip'}=$zip;
            $builds{$id}{'name'}=$name;
            $builds{$id}{'file'}=$file;
            $builds{$id}{'confopts'}=$confopts;
            $builds{$id}{'handcount'} = 0; # not handed out to anyone
            $builds{$id}{'done'} = 0; # not done
        }
    }
    close(F);
}


getbuilds("builds");

foreach my $id (keys %builds) {
    next if (-f "$dir/$id.png");

    my $text = $builds{$id}{'name'};
    print "long: $text => ";

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
    $text =~ s/Packard Bell *//i;

    print "short: $text\n";

    # create image with text                                                
    `convert -font helvetica -pointsize 13 -fill black -draw "text 1,13 '$text'" text-bg.png dump.png`;

    # rotate image                                                          
    `convert -rotate -90 dump.png $dir/$id.png`;
}

unlink "dump.png";
