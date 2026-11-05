#!/usr/bin/env bash
# A command-line front end: getopts, case, usage text and positional operands.

prog=backup

usage() {
    printf 'usage: %s [-v] [-n] [-o DIR] [-l LEVEL] FILE...\n' "$prog"
}

run_cli() {
    local OPTIND=1 opt
    local verbose=0 dry_run=0 out_dir="./out" level=3

    while getopts ":vno:l:h" opt; do
        case $opt in
            v) verbose=$((verbose + 1)) ;;
            n) dry_run=1 ;;
            o) out_dir=$OPTARG ;;
            l)
                case $OPTARG in
                    [1-9]) level=$OPTARG ;;
                    *) echo "error: bad level '$OPTARG'"; return 2 ;;
                esac
                ;;
            h) usage; return 0 ;;
            :) echo "error: -$OPTARG needs an argument"; usage; return 2 ;;
            \?) echo "error: unknown option -$OPTARG"; usage; return 2 ;;
        esac
    done
    shift $((OPTIND - 1))

    if (($# == 0)); then
        echo "error: no files given"
        return 1
    fi

    echo "verbose=$verbose dry_run=$dry_run out=$out_dir level=$level"
    local f n=0
    for f in "$@"; do
        n=$((n + 1))
        if ((dry_run)); then
            echo "  would copy [$f] -> $out_dir/${f##*/}"
        else
            echo "  copy [$f] -> $out_dir/${f##*/}"
        fi
    done
    ((verbose > 1)) && echo "  $n file(s) handled"
    return 0
}

try() {
    printf '$ %s' "$prog"
    printf ' %s' "$@"
    printf '\n'
    run_cli "$@"
    echo "-> status $?"
}

try -v a.txt
try -vv -n -o /srv/backups docs/one.md "two words.txt"
try -l 7 -o/tmp/x -- -file-with-dash
try -l 0 a
try -o
try -x a
try -n
try -h
try -nv -l5 dir/sub/file.tar.gz
