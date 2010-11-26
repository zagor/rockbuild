#!/bin/sh

build=$1
client=$2
rev=$3

perl tools/checksize.pl $build
perl tools/checklog.pl $rev $build
