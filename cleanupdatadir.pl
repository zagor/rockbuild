#!/usr/bin/perl

require 'rbmaster.pm';
readconfig();

my $dir=$rbconfig{storepath};

opendir(DIR, $dir) || die "can't opendir $dir: $!";
my @files = sort {$b <=> $a} grep { /.sizes$/ } readdir(DIR);
closedir DIR;

for (@files[20 .. $#files]) {
#    print "$_\n";
    if (/^(\d+)/) {
        `rm -f $dir/$1*`;
    }
}
