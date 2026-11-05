#!/usr/bin/env bash
# Arithmetic: (( )) and $(( )) with loops, bases, bit operations and a sieve.

echo "basic: $((7 + 3 * 2)) $(((7 + 3) * 2)) $((17 / 5)) $((17 % 5)) $((2 ** 10))"
echo "negative: $((-17 / 5)) $((-17 % 5)) $((-(3 - 8)))"
echo "bases: $((16#ff)) $((8#755)) $((2#101010)) $((0x1F)) $((010)) $((36#zz))"
echo "bits: $((5 & 3)) $((5 | 3)) $((5 ^ 3)) $((~5)) $((1 << 8)) $((256 >> 3))"
echo "logic: $((3 > 2 && 2 > 1)) $((0 || 0)) $((!7)) $((5 == 5 ? 100 : 200))"

a=5
((a += 10, a *= 2))
echo "compound: a=$a"
b=$((a++)) c=$((++a))
echo "increments: b=$b c=$c a=$a"
((a -= 30)) || echo "a reached $a, (( )) returned 1"
x=3 y=4
echo "pythagoras: $((x * x + y * y))"
name=x
echo "variable by name: $((name * 10)) $(( ${name} + 1 ))"

gcd() {
    local a=$1 b=$2 t
    while ((b)); do
        ((t = a % b, a = b, b = t))
    done
    echo "$a"
}
echo "gcd(1071, 462)=$(gcd 1071 462) gcd(17, 5)=$(gcd 17 5)"

# Sieve of Eratosthenes up to 100.
limit=100
declare -a composite=()
for ((i = 2; i * i <= limit; i++)); do
    ((composite[i])) && continue
    for ((j = i * i; j <= limit; j += i)); do
        composite[j]=1
    done
done
primes=()
for ((i = 2; i <= limit; i++)); do
    ((composite[i])) || primes+=("$i")
done
echo "primes below $limit (${#primes[@]}): ${primes[*]}"

# Collatz steps and a running maximum.
best=0 best_n=0
for ((n = 1; n <= 30; n++)); do
    steps=0 v=$n
    while ((v != 1)); do
        ((v % 2)) && ((v = 3 * v + 1)) || ((v /= 2))
        ((steps++))
    done
    ((steps > best)) && ((best = steps, best_n = n))
done
echo "longest Collatz chain below 31: n=$best_n steps=$best"

# Fixed-point percentages and rounding.
total=7 done_count=3
pct=$(( (done_count * 1000 / total + 5) / 10 ))
echo "progress: $done_count/$total = $pct%"
printf 'hex %x, octal %o, padded %06d\n' 48879 8 $((12 * 37))
declare -i counter=10
counter+=5
counter=counter*2
echo "declare -i: $counter"
echo "max int: $(( (1 << 62) - 1 + (1 << 62) ))"
