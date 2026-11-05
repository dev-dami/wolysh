#!/usr/bin/env bash
# A tiny template engine: {{var}}, {{var|upper}}, {{#if var}} blocks and loops.

declare -A vars=(
    [name]="Ada Lovelace"
    [role]=engineer
    [team]=compilers
    [admin]=1
    [items]="parser,lexer,optimizer"
)

render_line() {
    local line=$1 out="" key filter value
    local re='\{\{[[:space:]]*([a-z_]+)(\|([a-z]+))?[[:space:]]*\}\}'
    while [[ $line =~ $re ]]; do
        key=${BASH_REMATCH[1]}
        filter=${BASH_REMATCH[3]}
        value=${vars[$key]-"<$key?>"}
        case $filter in
            upper) value=${value^^} ;;
            lower) value=${value,,} ;;
            len) value=${#value} ;;
            "") ;;
            *) value="<bad filter $filter>" ;;
        esac
        out+=${line%%"${BASH_REMATCH[0]}"*}$value
        line=${line#*"${BASH_REMATCH[0]}"}
    done
    printf '%s\n' "$out$line"
}

render() {
    local line skip=0 cond item
    while IFS= read -r line; do
        if [[ $line =~ ^\{\{#if\ ([a-z_]+)\}\}$ ]]; then
            cond=${BASH_REMATCH[1]}
            [[ -n ${vars[$cond]-} && ${vars[$cond]} != 0 ]] && skip=0 || skip=1
            continue
        elif [[ $line == '{{/if}}' ]]; then
            skip=0
            continue
        elif [[ $line =~ ^\{\{#each\ ([a-z_]+)\}\}(.*)$ ]]; then
            local tmpl=${BASH_REMATCH[2]} list
            IFS=, read -ra list <<< "${vars[${BASH_REMATCH[1]}]}"
            for item in "${list[@]}"; do
                vars[it]=$item
                render_line "$tmpl"
            done
            continue
        fi
        ((skip)) || render_line "$line"
    done
}

render <<'TPL'
Hello, {{ name }}!
Role: {{role|upper}} on team {{team}} ({{team|len}} letters)
{{#if admin}}
You have admin rights, {{name|lower}}.
{{/if}}
{{#if guest}}
This line is hidden.
{{/if}}
Components:
{{#each items}}  - {{it}} ({{it|upper}})
Unknown: {{missing}} and {{role|bogus}}
Braces without a key stay: { not a tag } {{}}
TPL

vars[admin]=0
vars[name]="Grace Hopper"
render <<< $'{{#if admin}}\nadmin\n{{/if}}\nbye {{name}}'
