#!/usr/bin/env bash
# Functions: local scope, return codes, recursion and dynamic scoping.

counter=0

bump() {
    local step=${1:-1}
    counter=$((counter + step))
}

factorial() {
    local n=$1
    if ((n <= 1)); then
        echo 1
        return
    fi
    local sub
    sub=$(factorial $((n - 1)))
    echo $((n * sub))
}

fib() {
    local n=$1 a=0 b=1 t i
    for ((i = 0; i < n; i++)); do
        t=$((a + b)); a=$b; b=$t
    done
    echo "$a"
}

is_even() { (($1 % 2 == 0)); }

check_port() {
    local port=$1
    [[ $port =~ ^[0-9]+$ ]] || return 3
    ((port >= 1 && port <= 65535)) || return 4
    ((port < 1024)) && return 5
    return 0
}

outer() {
    local name="outer"
    inner
    echo "outer sees name=$name"
}

inner() {
    echo "inner sees name=$name"
    name="changed by inner"
}

name="global"

bump; bump 5; bump 10
echo "counter=$counter"
for n in 0 1 5 10; do
    echo "factorial($n)=$(factorial "$n") fib($n)=$(fib "$n")"
done
for n in 3 8; do
    if is_even "$n"; then echo "$n is even"; else echo "$n is odd"; fi
done
for p in 80 8080 0 99999 http; do
    check_port "$p"
    case $? in
        0) echo "$p: ok" ;;
        3) echo "$p: not a number" ;;
        4) echo "$p: out of range" ;;
        5) echo "$p: privileged" ;;
    esac
done
outer
echo "global name=$name"
