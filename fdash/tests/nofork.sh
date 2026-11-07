false; echo "1 $(echo hi) $?"
x=$(printf '%s-%s' a b); echo "2 $x $?"
y=$(test -f /nonexistent); echo "3 status $?"
z=$(command -v sh); echo "4 ${z##*/}"
f() { echo func; }; echo "5 $(f)"
echo() { printf 'mine\n'; }; w=$(echo x); unset -f echo; echo "6 $w"
i=0; v=$(printf %s $((i+=1))); echo "7 i=$i"
( q=$( [ 1 -eq ] ); echo "8 status $? [$q]" ) 2>/dev/null
set -e; r=$(printf ok); echo "9 $r"
