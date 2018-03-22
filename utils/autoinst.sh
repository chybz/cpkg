#!/usr/bin/env bash

ME=$(basename $0)
MYDIR=$(dirname $0)
MYDIR=$(cd $MYDIR && pwd)
MYTOPDIR=$(cd $MYDIR/.. && pwd)
UTILS=$MYTOPDIR/utils

$UTILS/install-deps.sh

cd $MYTOPDIR
./cpkg/bin/cpkg configure
echo "====== Makefile"
cat Makefile
make update-pkg
