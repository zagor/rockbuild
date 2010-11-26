#!/usr/bin/perl
require "rbmaster.pm";

readconfig();
exit if (not $rbconfig{ciaenabled});

if (scalar @ARGV < 1) {
    print "usage: $0 [revision]\n";
    exit;
}
my $rev = $ARGV[0];

my $user = `svnlook author $rbconfig{svnpath} --revision $rev`;
chomp $user;

db_connect();
my $sth = $db->prepare("SELECT sum(errors), sum(warnings) FROM builds WHERE revision=$rev") or
    warn "DBI: Can't prepare statement: ". $db->errstr;
my $rows = $sth->execute();
if ($rows) {
    my ($errors,$warnings) = $sth->fetchrow_array();
    if ($errors or $warnings) {
        $logmsg = "$errors errors, $warnings warnings ($user committed)\n";
    }
    else {
        $logmsg = "All green";
    }
}

my ($VERSION) = '2.3';
my ($URL) = 'http://cia.vc/clients/cvs/ciabot_cvs.pl';
my $ts = time;
my $project = $rbconfig{ciaproject};
my $module = $rbconfig{ciamodule};

$message = <<EM
<message>
   <generator>
       <name>CIA Perl client for CVS</name>
       <version>$VERSION</version>
       <url>$URL</url>
   </generator>
   <source>
       <project>$project</project>
       <module>$module</module>
   </source>
   <timestamp>
       $ts
   </timestamp>
   <body>
       <commit>
           <author>$user</author>
           <revision>$rev</revision>
           <log>
$logmsg
           </log>
       </commit>
   </body>
</message>
EM
;

#print $message;
#exit;

require RPC::XML;
require RPC::XML::Client;
my $rpc_client = new RPC::XML::Client 'http://cia.vc/RPC2';
my $rpc_request = RPC::XML::request->new('hub.deliver', $message);
my $rpc_response = $rpc_client->send_request($rpc_request);
