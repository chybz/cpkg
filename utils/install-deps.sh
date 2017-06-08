#!/usr/bin/env bash

ME=$(basename $0)
MYDIR=$(dirname $0)
MYDIR=$(cd $MYDIR && pwd)
MYTOPDIR=$(cd $MYDIR/.. && pwd)

sudo apt-get -qq update
sudo apt-get install -y lintian rsync pkg-config tinycdb apt-file fakeroot
