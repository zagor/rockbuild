#!/usr/bin/perl

use CGI 'param';
use File::Copy;
use File::Basename;

sub ulog {
    if (open(L, ">>$cwd/upload.log")) {
        print L strftime("%F %T ", localtime()), $_[0], "\n";
        close(L);
    }
}

my $cwd = dirname $0;
my $cgi = basename $0;

my $filename = param("upfile");
my $fh = CGI::upload("upfile");

$filename =~ s/[\;\:\!\?\*\"\'\,\ ]/_/g;
print STDERR "Uploading $filename\n";

print "Content-type: text/plain\n";

#for (param()) {
#    printf "$_: %s\n", param($_);
#}
#exit;

my $destpath="$cwd/upload";

if (-f "$destpath/$filename") {
    print "Status: 403 Cannot overwrite file\n";
    exit;
}

if (open OUTFILE, ">$destpath/$filename") {
    while ($bytesread=read($fh,$buffer,1024)) {
        print OUTFILE $buffer;
    }
    close OUTFILE;
    print "Status: 200 Upload successful\n";
    ulog "Uploaded upload/$filename";
}
else {
    print "Status: 502 File copy failed: $!\n";
    ulog "Failed creating upload/$filename";
}

print "\n$destpath/$filename\n";
print STDERR "\n$destpath/$filename\n";
