#!/bin/sh
# fdash-update-completions [-o DIR] [COMMAND...]
#
# Writes completion specs from the man pages (sections 1 and 8) of commands
# that have no hand-written spec, as fish_update_completions does: the options
# and the first sentence that describes each. They go to
# ~/.local/share/fdash/generated_completions, where fdash looks last. With
# commands named, only those are done; -o writes elsewhere, for example
# /usr/local/share/fdash/generated_completions for every user.
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -u
datadir=${FDASH_DATADIR:-/usr/local/share/fdash}
out=${XDG_DATA_HOME:-${HOME:-/nonexistent}/.local/share}/fdash/generated_completions
own=${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/fdash/completions

usage() {
	echo "usage: fdash-update-completions [-o DIR] [COMMAND...]" >&2
	exit 2
}

while getopts o:h opt; do
	case $opt in
	o) out=$OPTARG ;;
	*) usage ;;
	esac
done
shift $((OPTIND - 1))

manpath=${MANPATH:-}
[ -n "$manpath" ] || manpath=$(manpath 2>/dev/null) || manpath=
[ -n "$manpath" ] || manpath=/usr/local/share/man:/usr/share/man

tmp=$(mktemp -d "${TMPDIR:-/tmp}/fdash-man.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM
mkdir "$tmp/out"

# One page behind a line naming it; the first in MANPATH wins.
page() {
	f=$1
	[ -f "$f" ] || return 0
	name=${f##*/}
	case $name in
	*.gz) dec='gzip -dc' name=${name%.gz} ;;
	*.xz) dec='xz -dc' name=${name%.xz} ;;
	*.bz2) dec='bzip2 -dc' name=${name%.bz2} ;;
	*.zst) dec='zstd -dc' name=${name%.zst} ;;
	*) dec=cat ;;
	esac
	cmd=${name%.*}
	case $cmd in
	''|.*|*[!A-Za-z0-9_.+@%[-]*) return 0 ;;
	esac
	case $seen in
	*" $cmd "*) return 0 ;;
	esac
	seen="$seen$cmd "
	[ -e "$own/$cmd" ] || [ -e "$datadir/completions/$cmd" ] && return 0
	printf '.FDASHPAGE %s\n' "$cmd"
	IFS=' '
	$dec "$f" 2>/dev/null
	IFS=:
	printf '\n'
}

pages() {
	seen=' '
	IFS=:
	for dir in $manpath; do
		[ -n "$dir" ] || continue
		if [ $# -eq 0 ]; then
			for f in "$dir"/man1/* "$dir"/man8/*; do
				page "$f"
			done
		else
			for cmd; do
				for f in "$dir"/man1/"$cmd".* "$dir"/man8/"$cmd".*; do
					page "$f"
				done
			done
		fi
	done
	IFS=' '
}

pages "$@" | LC_ALL=C awk -v out="$tmp/out" '
# Text of roff escapes: fonts and sizes go, special characters become plain ones.
function clean(s) {
	gsub(/\\f(\[[^]]*\]|\(..|.)/, "", s)
	gsub(/\\s[-+]?[0-9]+/, "", s)
	gsub(/\\\*(\[[^]]*\]|\(..|.)/, "", s)
	gsub(/\\\((em|en)|\\\[(em|en)\]/, "-", s)
	gsub(/\\\((aq|cq|oq)|\\\[(aq|cq|oq)\]/, "\047", s)
	gsub(/\\\((lq|rq|dq)|\\\[(lq|rq|dq)\]/, "\"", s)
	gsub(/\\\(bu|\\\[bu\]/, "*", s)
	gsub(/\\\(..|\\\[[^]]*\]/, "", s)
	gsub(/\\-/, "-", s)
	gsub(/\\e/, "\\\\", s)
	gsub(/\\[&%:|^c\/,]/, "", s)
	gsub(/\\ /, " ", s)
	return s
}

# The arguments of a macro line, quotes respected, joined by sep.
function margs(s, sep,    r, t, n, i) {
	r = ""; n = 0
	while (s != "") {
		sub(/^[ \t]+/, "", s)
		if (s == "") break
		if (substr(s, 1, 1) == "\"") {
			s = substr(s, 2)
			if ((i = index(s, "\"")) == 0) i = length(s) + 1
			t = substr(s, 1, i - 1)
			s = substr(s, i + 1)
		} else {
			match(s, /^[^ \t]+/)
			t = substr(s, 1, RLENGTH)
			s = substr(s, RLENGTH + 1)
		}
		r = r (n++ ? sep : "") t
	}
	return r
}

# mdoc: macro names go, Fl makes options, punctuation sticks to the word before.
function mdoc(s,    n, w, i, r, fl, ns, t) {
	n = split(s, w, /[ \t]+/)
	r = ""; fl = 0; ns = 1
	for (i = 1; i <= n; i++) {
		t = w[i]
		if (t == "") continue
		if (t == "Fl") { fl = 1; continue }
		if (t == "Ns") { ns = 1; continue }
		if (t ~ /^[A-Z][a-z][a-z]?$/ && t != "No") {
			if (fl) { r = r (ns ? "" : " ") "-"; ns = 1; fl = 0 }
			continue
		}
		if (t == "No") continue
		if (fl) { t = "-" t; fl = 0 }
		if (t ~ /^[,.;:)]$/) ns = 1
		r = r (ns ? "" : " ") t
		ns = (t == "(")
	}
	if (fl) r = r (ns ? "" : " ") "-"
	return r
}

function text_of(line,    m, rest) {
	if (line !~ /^[.\047]/) return clean(line)
	m = line; sub(/^[.\047][ \t]*/, "", m)
	rest = m; sub(/^[^ \t]+[ \t]*/, "", rest); sub(/[ \t].*/, "", m)
	if (m ~ /^(B|I|SM|SB)$/) return clean(margs(rest, " "))
	if (m ~ /^(BR|RB|IR|RI|BI|IB)$/) return clean(margs(rest, ""))
	if (m ~ /^[A-Z][a-z]$/ && m !~ /^(Sh|Ss|Bl|El|Bd|Ed|It|Pp|Dt|Dd|Os|Nd)$/) return clean(mdoc(m " " rest))
	return ""
}

# Options in a tag such as "-a, --all" or "--color[=WHEN]"; empty unless it starts with one.
function tag_options(tag,    n, w, i, o, r) {
	gsub(/[|,]/, " ", tag)
	sub(/^[ \t]+/, "", tag)
	if (tag !~ /^-/) return ""
	n = split(tag, w, /[ \t]+/)
	r = ""
	for (i = 1; i <= n; i++) {
		o = w[i]
		if (o !~ /^-/) continue
		sub(/[=[<].*/, "", o)
		if (o ~ /^--?[A-Za-z0-9?#@][A-Za-z0-9_.+?#@-]*$/) r = r " " o
	}
	return r
}

function flush(    n, o, i, d, cut) {
	if (opts != "") {
		d = desc
		gsub(/[ \t]+/, " ", d)
		sub(/^ /, "", d)
		# the first sentence: "i.e. this" and "with ." go on
		if (match(d, /[A-Za-z0-9)\047"][.] [A-Z]/)) d = substr(d, 1, RSTART)
		sub(/[ :;,]+$/, "", d)
		if (d ~ /[A-Za-z0-9)][.]$/) d = substr(d, 1, length(d) - 1)
		if (length(d) > 70) {
			d = substr(d, 1, 70)
			sub(/ [^ ]*$/, "", d)
			d = d "..."
		}
		d = toupper(substr(d, 1, 1)) substr(d, 2)
		n = split(opts, o, " ")
		for (i = 1; i <= n; i++) {
			if (o[i] == "" || (page SUBSEP o[i]) in done) continue
			done[page, o[i]] = 1
			if (!written) {
				file = out "/" page
				print "# From the man page, by fdash-update-completions" > file
				written = 1
				pages_done++
			}
			print o[i] (d == "" ? "" : "\t" d) > file
		}
	}
	opts = ""; desc = ""; tagnext = 0
}

function endpage() {
	flush()
	if (written) close(file)
	written = 0
}

/^\.FDASHPAGE / { endpage(); page = $2; next }
/^[.\047][ \t]*\\"/ { next }
/^[.\047][ \t]*(SH|Sh|SS|Ss|PP|P|LP|HP|El|Bl|RE|RS|Pp|Bd|Ed)([ \t]|$)/ { flush(); next }
/^[.\047][ \t]*TP([ \t]|$)/ { flush(); tagnext = 1; next }
/^[.\047][ \t]*TQ([ \t]|$)/ { tagnext = 2; next }
/^[.\047][ \t]*IP([ \t]|$)/ {
	flush()
	t = $0; sub(/^[.\047][ \t]*IP[ \t]*/, "", t)
	t = margs(t, "\034")
	sub(/\034.*/, "", t)
	opts = tag_options(clean(t))
	next
}
/^[.\047][ \t]*It([ \t]|$)/ {
	flush()
	t = $0; sub(/^[.\047][ \t]*It[ \t]*/, "", t)
	opts = tag_options(clean(mdoc(t)))
	next
}
{
	t = text_of($0)
	if (t == "" && $0 ~ /^[.\047]/) next
	if (tagnext) {
		o = tag_options(t)
		opts = (tagnext == 2 ? opts : "") o
		tagnext = 0
		next
	}
	if (opts != "" && length(desc) < 400) desc = desc " " t
}
END { endpage(); print pages_done + 0 }
' >"$tmp/count" || exit 1

mkdir -p "$out" || exit 1
if [ $# -eq 0 ]; then
	# all of them: what is gone from the man pages goes from here too
	for f in "$out"/*; do
		[ -f "$f" ] && rm -f "$f"
	done
fi
for cmd; do
	rm -f "$out/$cmd"
done
for f in "$tmp/out"/*; do
	[ -f "$f" ] && mv -f "$f" "$out/"
done
echo "fdash: $(cat "$tmp/count") completion specs from man pages in $out"
