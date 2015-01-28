#!/usr/bin/env bash
#
# american fuzzy lop - corpus minimization tool
# ---------------------------------------------
#
# Written and maintained by Michal Zalewski <lcamtuf@google.com>
#
# Copyright 2014 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at:
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# This tool tries to find the smallest subset of files in the input directory
# that still trigger the full range of instrumentation data points seen in
# the starting corpus. This has two uses:
#
#   - Screening large corpora of input files before using them as a seed for
#     seed for afl-fuzz,
#
#   - Cleaning up the corpus generated by afl-fuzz.
#
# The tool assumes that the tested program reads from stdin and requires no
# cmdline parameters; very simple edits are required to support other use
# cases (search for "EDIT HERE").
#
# If you set AFL_EDGES_ONLY beforehand, the afl-showmap utility will only
# report branch hit information, not hit counts, producing a more traditional
# and smaller corpus that more directly maps to edge coverage.
#

echo "corpus minimization tool for afl-fuzz by <lcamtuf@google.com>"
echo


if [ ! "$#" = "2" ]; then
  echo "Usage: $0 /path/to/corpus_dir /path/to/tested_binary" 1>&2
  echo 1>&2
  echo "Note: the tested binary must accept input on stdin and require no additional" 1>&2
  echo "parameters. For more complex use cases, you need to edit this script." 1>&2
  echo 1>&2
  exit 1
fi

DIR="`echo "$1" | sed 's/\/$//'`"
BIN="$2"

echo "$DIR" | grep -qE '^(|/var)/tmp/'
T1="$?"

echo "$BIN" | grep -qE '^(|/var)/tmp/'
T2="$?"

echo "$PWD" | grep -qE '^(|/var)/tmp/'
T3="$?"

if [ "$T1" = "0" -o "$T2" = "0" -o "$T3" = "0" ]; then
  echo "Error: do not use this script with /tmp or /var/tmp (it's just not safe)." 1>&2
  exit 1
fi

if [ ! -f "$BIN" -o ! -x "$BIN" ]; then
  echo "Error: binary '$2' not found or is not executable." 1>&2
  exit 1
fi

if [ ! -d "$DIR" ]; then
  echo "Error: directory '$1' not found." 1>&2
  exit 1
fi

# Try to find afl-showmap somewhere...

if [ "$AFL_PATH" = "" ]; then
  SM=`which afl-showmap 2>/dev/null`
  test "$SM" = "" && SM="/usr/local/bin/afl-showmap"
else
  SM="$AFL_PATH/afl-showmap"
fi

if [ ! -x "$SM" ]; then
  echo "Can't find 'afl-showmap' - please set AFL_PATH."
  exit 1
fi

CCOUNT=$((`ls -- "$DIR" 2>/dev/null | wc -l`))

if [ "$CCOUNT" = "0" ]; then
  echo "No inputs in the target directory - nothing to be done."
  exit 0
fi

rm -rf .traces 2>/dev/null
mkdir .traces || exit 1

if [ "$AFL_EDGES_ONLY" = "" ]; then
  OUT_DIR="$DIR.minimized"
else
  OUT_DIR="$DIR.edges.minimized"
fi

rm -rf -- "$OUT_DIR" 2>/dev/null
mkdir "$OUT_DIR" || exit 1

if [ -d "$DIR/queue" ]; then
  DIR="$DIR/queue"
fi

echo "[*] Obtaining traces for input files in '$DIR'..."

# Start with the bare necessities...

(

  CUR=0

  ulimit -v 100000 2>/dev/null
  ulimit -d 100000 2>/dev/null

  for fn in `ls "$DIR"`; do

    CUR=$((CUR+1))
    printf "\\r    Processing file $CUR/$CCOUNT... "

    # *** EDIT HERE ***
    # Modify the following line if "$BIN" needs to be called with additional
    # parameters or so ("$DIR/$fn" is the actual test case).

    AFL_MINIMIZE_MODE=1 "$SM" "$BIN" <"$DIR/$fn" >".traces/$fn" 2>&1

  done

)

echo
echo "[*] Sorting trace sets (this may take a while)..."

# Sort all tuples by popularity across all datasets. The reasoning here is that
# we need to start by adding the traces for least-popular tuples anyway (we have
# little or no choice), and we can take care of the rest in some smarter way.

ls "$DIR" | sed 's/^/.traces\//' | xargs -n 1 cat | sort | \
  uniq -c | sort -n >.traces/.all_uniq

TCOUNT=$((`grep -c . .traces/.all_uniq`))

echo "[+] Found $TCOUNT unique tuples across $CCOUNT files."

echo "[*] Finding best candidates for each tuple..."

# Find best file for each tuple, where "best" is simply understood as the
# smallest containing a particular tuple in its trace; empirical evidence
# suggests that this usually produces smaller data sets than more involved
# approaches that would be still viable in a shell script.

# The weird default-value construct is used simply because it's noticably
# faster than a proper if / test block; the call to ls -rS takes care of
# starting with the smallest files first.

CUR=0

for fn in `ls -rS "$DIR"`; do

  CUR=$((CUR+1))
  printf "\\r    Processing file $CUR/$CCOUNT... "

  for tuple in `cat ".traces/$fn"`; do

    BEST_FILE[tuple]="${BEST_FILE[tuple]:-$fn}"

  done

done

echo
echo "[*] Processing candidates and writing output files..."

touch .traces/.already_have

CUR=0

# Grab the top pick for each tuple, unless said tuple is already set due to the
# inclusion of an earlier candidate. Work from least popular tuples and toward
# the most common ones.

while read -r cnt tuple; do

  CUR=$((CUR+1))
  printf "\\r    Processing tuple $CUR/$TCOUNT... "

  # If we already have this tuple, skip it.

  grep -q "^$tuple\$" .traces/.already_have && continue

  FN=${BEST_FILE[tuple]}

  ln "$DIR/$FN" "$OUT_DIR/$FN"

  if [ "$((CUR % 5))" = "0" ]; then
    cat ".traces/$FN" ".traces/.already_have" | sort -u >.traces/.tmp
    mv -f .traces/.tmp .traces/.already_have
  else
    cat ".traces/$FN" >>".traces/.already_have"
  fi

done <.traces/.all_uniq

NCOUNT=`ls -- "$OUT_DIR" | wc -l`

echo
echo "[+] Narrowed down to $NCOUNT files, saved in '$OUT_DIR'."

rm -rf .traces