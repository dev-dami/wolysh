#!/usr/bin/env bash
# A JSON-ish pretty printer: walks the input one character at a time.

pretty() {
    local s=$1 out="" indent=0 in_str=0 esc=0 c i pad
    local n=${#s}
    newline() { printf -v pad '%*s' $((indent * 2)) ''; out+=$'\n'$pad; }
    for ((i = 0; i < n; i++)); do
        c=${s:i:1}
        if ((in_str)); then
            out+=$c
            if ((esc)); then esc=0
            elif [[ $c == '\' ]]; then esc=1
            elif [[ $c == '"' ]]; then in_str=0
            fi
            continue
        fi
        case $c in
            '"') in_str=1; out+=$c ;;
            '{' | '[')
                out+=$c
                # Keep empty containers on one line.
                if [[ ${s:i+1:1} == '}' || ${s:i+1:1} == ']' ]]; then
                    out+=${s:i+1:1}; i=$((i + 1))
                else
                    indent=$((indent + 1)); newline
                fi
                ;;
            '}' | ']') indent=$((indent - 1)); newline; out+=$c ;;
            ',') out+=$c; newline ;;
            ':') out+=': ' ;;
            ' ' | $'\t' | $'\n') ;;
            *) out+=$c ;;
        esac
    done
    printf '%s\n' "$out"
}

# Count keys, strings, numbers and literals with a regex scan.
stats() {
    local rest=$1 keys=0 strings=0 numbers=0 literals=0 bare="" tok
    local re='^([^"]*)"(([^"\\]|\\.)*)"[[:space:]]*(:?)(.*)$'
    while [[ $rest =~ $re ]]; do
        bare+="${BASH_REMATCH[1]} "
        if [[ -n ${BASH_REMATCH[4]} ]]; then
            keys=$((keys + 1))
        else
            strings=$((strings + 1))
        fi
        rest=${BASH_REMATCH[5]}
    done
    bare+=$rest
    for tok in ${bare//[^0-9a-z.]/ }; do
        if [[ $tok =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            numbers=$((numbers + 1))
        else
            literals=$((literals + 1))
        fi
    done
    echo "keys=$keys strings=$strings numbers=$numbers literals=$literals"
}

doc='{"name":"wolysh","version":"1.0.0","tags":["shell","zig"],"deps":{},"limits":{"depth":256,"words":4194304,"ratio":0.5},"note":"a \"quoted\" word, with: punctuation {}","empty":[],"nested":[[1,2],[3,[4]]]}'

pretty "$doc"
stats "$doc"
pretty '[]'
small='{"a" : 1 ,  "b" : [ true , false , null ] }'
pretty "$small"
stats "$small"
