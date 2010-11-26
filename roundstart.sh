#!/bin/sh

rev=$1

touch data/build_running
perl tools/showbuilds.pl $rev > builds.html
