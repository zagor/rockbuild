#!/bin/sh
trap "exit" INT

while true
do
    if [ -f "rbclient.pl.new" ]; then
        mv "rbclient.pl.new" "rbclient.pl"
    fi
    perl -s rbclient.pl -username=name -password=pwd -archlist=arm,m68k,mipsel,sh,sdl,arm-eabi-gcc444,android -clientname=test -port=19998 -buildmaster=localhost
    res=$?
    if test "$res" -eq 22; then
      echo "Address the above issue(s), then restart!"
      exit
    fi
    sleep 30
done
