#!/bin/sh

rev=$1

# talk to rasher before removing this
cat data/$rev*.size > data/$rev.sizes

perl tools/clientstats.pl $rev > data/$rev-clients.html

perl tools/showbuilds.pl > builds.html
perl tools/showbuilds.pl 1 > builds_all.html
perl tools/showsize.pl > sizes.html
perl tools/mktitlepics.pl
perl tools/cleanupdatadir.pl
perl tools/cia_result.pl $rev

# make build-info for rbutil
echo "[bleeding]" > build-info
date +'timestamp = "%Y%m%dT%H%M%SZ"' >> build-info
echo -n 'rev = "' >> build-info
echo -n $rev >> build-info
echo '"' >> build-info

rm data/build_running
