a=hello; f=/etc/passwd; n=7
[[ $a == h* ]] && echo 1 yes
[[ $a == "h*" ]] || echo 2 quoted-is-literal
[[ $a != x* && -f $f ]] && echo 3 and
[[ -d $f || $n -gt 5 ]] && echo 4 or
[[ ! -e /nonexistent ]] && echo 5 not
[[ ( $a == hello ) && ( $n -eq 7 ) ]] && echo 6 parens
[[ abc < abd ]] && echo 7 less
[[ $a =~ ^h(el)+lo$ && ! $a =~ ^(x|y) ]] && echo 8 regex
[[ $a =~ "h.llo" ]] || echo 9 quoted-regex-literal
x="two words"; [[ $x == "two words" ]] && echo 10 nosplit
[[ $n+1 -eq 8 ]] && echo 11 arith
[[ -z "" && -n $a ]] && echo 12 zn
[[ -v a && ! -v nope ]] && echo 13 v
[[ $a ]] && echo 14 nonempty
if [[ $a == hel* ]]; then echo 15 if; fi
[[ $a == hello &&
   $n == 7 ]] && echo 16 newline
cat <<< "17 here $a"
read -r w1 w2 <<< "18 two"; echo "$w1 $w2"
tr a-z A-Z <<< 'nineteen $a'
( [[ 1 -eq ]] ) 2>/dev/null; echo "20 status $?"
