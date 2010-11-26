#!/usr/bin/perl

require 'rbmaster.pm';
readconfig();

my $dir = $rbconfig{titledir};

getbuilds();

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
