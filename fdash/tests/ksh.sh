v=abcdef
echo "1 ${v:2}|${v:1:3}|${v: -2}|${v:(-3):2}|${v:1:-1}|${v:10}|"
echo "2 ${v/cd/XY}"
p=a/b/c
echo "3 ${p//\//:} ${p//[ab]/X} ${p/#a/Z} ${p/%c/Z}"
pre=/usr; path=/usr/bin
echo "4 ${path/$pre/X}"
w=hello; u=ABC
echo "5 ${v^^} ${w^} ${u,,} ${u,}"
r=Привет
echo "6 ${r^^} ${r:1:3} ${r/ив/IV}"
echo "7 ${v/x*/Q} ${v//?/.} ${v/b*e/-}"
x="a b  c"; set -- ${x// /_}; echo "8 $# $1"
unset z; echo "9 [${z:0:1}][${z/a/b}][${z^^}]"
f=file.tar.gz; echo "10 ${f/.*/} ${v/"c"/C} ${v//c/$w} ${v/#/<} ${v/%/>}"
set -- one two; echo "11 ${1:1} ${2^}"
echo "12 ${v//[!ace]/}"
g='a*b'; echo "13 ${g/\*/+} ${g/'*'/-}"
