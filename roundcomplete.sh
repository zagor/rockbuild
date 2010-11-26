#!/bin/sh

rev=$1

# talk to rasher before removing this
cat data/$rev*.size > data/$rev.sizes

perl clientstats.pl $rev > data/$rev-clients.html

perl showbuilds.pl > builds.html
perl showbuilds.pl 1 > builds_all.html
perl showsize.pl > sizes.html
perl mktitlepics.pl
perl cleanupdatadir.pl
perl cia_result.pl $rev

# make build-info for rbutil
echo "[bleeding]" > build-info
date +'timestamp = "%Y%m%dT%H%M%SZ"' >> build-info
echo -n 'rev = "' >> build-info
echo -n $rev >> build-info
echo '"' >> build-info

rm data/build_running
