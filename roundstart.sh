#!/bin/sh

rev=$1

touch data/build_running
perl showbuilds.pl $rev > builds.html

#rm -f data/rockbox-*.zip
#rm -f data/rockbox.7z
