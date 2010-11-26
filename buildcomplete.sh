#!/bin/sh

build=$1
client=$2
rev=$3

perl checksize.pl $build
perl checklog.pl $rev $build
