#!/bin/sh
#
# Figured out by looking at some binaries without code.
#
#
infile=${1:-u-boot.scr.txt}
outfile=${2:-u-boot.scr}

mkimage -C none -A arm -n "boot script" -T script -d $infile $outfile
