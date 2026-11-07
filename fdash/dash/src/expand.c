/*-
 * Copyright (c) 1991, 1993
 *	The Regents of the University of California.  All rights reserved.
 * Copyright (c) 1997-2005
 *	Herbert Xu <herbert@gondor.apana.org.au>.  All rights reserved.
 *
 * This code is derived from software contributed to Berkeley by
 * Kenneth Almquist.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. Neither the name of the University nor the names of its contributors
 *    may be used to endorse or promote products derived from this software
 *    without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#include <ctype.h>
#include <dirent.h>
#ifdef HAVE_FNMATCH
#include <fnmatch.h>
#endif
#ifdef HAVE_GLOB
#include <glob.h>
#endif
#include <inttypes.h>
#include <limits.h>
#ifdef HAVE_GETPWNAM
#include <pwd.h>
#endif
#include <setjmp.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <unistd.h>
#include <wchar.h>
#include <wctype.h>

/*
 * Routines to expand arguments to commands.  We have to deal with
 * backquotes, shell variables, and file metacharacters.
 */

#include "error.h"
#include "eval.h"
#include "expand.h"
#include "jobs.h"
#include "main.h"
#include "memalloc.h"
#include "mystring.h"
#include "nodes.h"
#include "options.h"
#include "output.h"
#include "parser.h"
#include "shell.h"
#include "show.h"
#include "syntax.h"
#include "system.h"
#include "var.h"
#ifdef FDASH
#include <alloca.h>
#endif

/*
 * _rmescape() flags
 */
#define RMESCAPE_ALLOC	0x1	/* Allocate a new string */
#define RMESCAPE_GLOB	0x2	/* Add backslashes for glob */
#define RMESCAPE_GROW	0x8	/* Grow strings instead of stalloc */
#define RMESCAPE_HEAP	0x10	/* Malloc strings instead of stalloc */

/* Add CTLESC when necessary. */
#define QUOTES_ESC	(EXP_FULL | EXP_CASE)

/*
 * Structure specifying which parts of the string should be searched
 * for IFS characters.
 */

struct ifsregion {
	struct ifsregion *next;	/* next region in list */
	int begoff;		/* offset of start of region */
	int endoff;		/* offset of end of region */
	int nulonly;		/* search for nul bytes only */
};

struct ifs_state {
	const char *ifs;
	char *start;
	char *r;
	int maxargs;
	int ifsspc;
};

/* output of current string */
static char *expdest;
/* list of back quote expressions */
static struct nodelist *argbackq;
/* first struct in list of ifs regions */
static struct ifsregion ifsfirst;
/* last struct in list */
static struct ifsregion *ifslastp;
/* holds expanded arg list */
static struct arglist exparg;

static char ifsmap[128];
static const char *ncifs;
static size_t ifsmb0len;
static wchar_t *wcifs;

static char *argstr(char *p, int flag);
static char *exptilde(char *startp, int flag);
static char *expari(char *start, int flag);
STATIC void expbackq(union node *, int);
STATIC char *evalvar(char *, int);
static size_t strtodest(const char *p, int flags);
static size_t memtodest(const char *p, size_t len, int flags);
#ifdef FDASH
static ssize_t varvalue(char *name, int varflags, unsigned flags);
#endif
STATIC ssize_t varvalue(char *, int, unsigned);
STATIC void expandmeta(struct strlist *);
static void addglob(const glob64_t *);
static char *expmeta(char *, unsigned, size_t);
STATIC struct strlist *expsort(struct strlist *);
STATIC struct strlist *msort(struct strlist *, int);
STATIC void addfname(char *);
STATIC int patmatch(char *, const char *);
STATIC int pmatch(char *, const char *);
static size_t cvtnum(intmax_t num, int flags);
STATIC void varunset(const char *, const char *, const char *, int)
	__attribute__((__noreturn__));


/*
 * Prepare a pattern for a glob(3) call.
 *
 * Returns an stalloced string.
 */

STATIC inline char *
preglob(const char *pattern, int flag) {
	if (FNMATCH_IS_ENABLED) {
		if (!flag)
			flag = RMESCAPE_GROW;
		flag |= RMESCAPE_ALLOC;
	}
	flag |= RMESCAPE_GLOB;
	return _rmescapes((char *)pattern, flag);
}


static size_t mesclen(const char *start, const char *p, char mesc) {
	size_t esc = 0;

	while (p > start && *--p == mesc) {
		esc++;
	}
	return esc;
}

static size_t esclen(const char *start, const char *p) {
	return mesclen(start, p, CTLESC);
}

static __attribute__((noinline)) unsigned mbnext(const char *p)
{
	unsigned start = 0;
	unsigned end = 0;
	unsigned ml;
	int c;

	c = (signed char)p[end++];

	switch (__builtin_expect(c, 0)) {
	case CTLMBCHAR:
		if ((signed char)p[end] == CTLESC)
			end++;
		ml = (unsigned char)p[end++];
		start = end;
		end = ml + 2;
		break;
	case CTLESC:
		start++;
		break;
	}

	return start | end << 8;
}

static inline const char *getpwhome(const char *name)
{
#ifdef HAVE_GETPWNAM
	struct passwd *pw = getpwnam(name);
	return pw ? pw->pw_dir : 0;
#else
	return 0;
#endif
}


/*
 * Perform variable substitution and command substitution on an argument,
 * placing the resulting list of arguments in arglist.  If EXP_FULL is true,
 * perform splitting and file name expansion.  When arglist is NULL, perform
 * here document expansion.
 */

void
expandarg(union node *arg, struct arglist *arglist, int flag)
{
	struct strlist *sp;
	char *p;

	argbackq = arg->narg.backquote;
	STARTSTACKSTR(expdest);
	argstr(arg->narg.text, flag);
	if (arglist == NULL) {
		/* here document expanded */
		goto out;
	}
	p = grabstackstr(expdest);
	exparg.lastp = &exparg.list;
	/*
	 * TODO - EXP_REDIR
	 */
	if (flag & EXP_FULL) {
		ifsbreakup(p, -1, &exparg);
		*exparg.lastp = NULL;
		exparg.lastp = &exparg.list;
		expandmeta(exparg.list);
	} else {
		sp = (struct strlist *)stalloc(sizeof (struct strlist));
		sp->text = p;
		*exparg.lastp = sp;
		exparg.lastp = &sp->next;
	}
	*exparg.lastp = NULL;
	if (exparg.list) {
		*arglist->lastp = exparg.list;
		arglist->lastp = exparg.lastp;
	}

out:
	ifsfree();
}



/*
 * Perform variable and command substitution.  If EXP_FULL is set, output CTLESC
 * characters to allow for further processing.  Otherwise treat
 * $@ like $* since no splitting will be performed.
 */

static char *argstr(char *p, int flag)
{
	static const char spclchars[] = {
		'=',
		':',
		CTLQUOTEMARK,
		CTLENDVAR,
		CTLESC,
		CTLVAR,
		CTLBACKQ,
		CTLMBCHAR,
		CTLARI,
		CTLENDARI,
		0
	};
	const char *reject = spclchars;
	int c;
	int breakall = (flag & (EXP_WORD | EXP_QUOTED)) == EXP_WORD;
	int inquotes;
	size_t length;
	int startloc;

	reject += !!(flag & EXP_VARTILDE2);
	reject += flag & EXP_VARTILDE ? 0 : 2;
	inquotes = 0;
	length = 0;
	if (flag & EXP_TILDE) {
		flag &= ~EXP_TILDE;
tilde:
		if (*p == '~')
			p = exptilde(p, flag);
	}
start:
	startloc = expdest - (char *)stackblock();
	for (;;) {
		unsigned ml;
		unsigned mb;
		int end;

		length += strcspn(p + length, reject);
		end = 0;
		c = (signed char)p[length];
		if (!(c & 0x80) || c == CTLENDARI || c == CTLENDVAR) {
			/*
			 * c == '=' || c == ':' || c == '\0' ||
			 * c == CTLENDARI || c == CTLENDVAR
			 */
			length++;
			/* c == '\0' || c == CTLENDARI || c == CTLENDVAR */
			end = !!((c - 1) & 0x80);
		}
		if (length > 0 && !(flag & EXP_DISCARD)) {
			int newloc;
			char *q;

			q = stnputs(p, length, expdest);
			q[-1] &= end - 1;
			expdest = q - (flag & EXP_WORD ? end : 0);
			newloc = q - (char *)stackblock() - end;
			if (breakall && !inquotes && newloc > startloc) {
				recordregion(startloc, newloc, 0);
			}
			startloc = newloc;
		}
		p += length + 1;
		length = 0;

		if (end)
			break;

		switch (c) {
		case '=':
			flag |= EXP_VARTILDE2;
			reject++;
			/* fall through */
		case ':':
			/*
			 * sort of a hack - expand tildes in variable
			 * assignments (after the first '=' and after ':'s).
			 */
			if (*--p == '~') {
				goto tilde;
			}
			continue;
		case CTLQUOTEMARK:
			/* "$@" syntax adherence hack */
			if (!inquotes && !strcmp(p, dolatstr + 1)) {
				p = evalvar(p + 1, flag | EXP_QUOTED) + 1;
				goto start;
			}
			inquotes ^= EXP_QUOTED;
addquote:
			if (flag & QUOTES_ESC) {
				p--;
				length++;
				startloc++;
			}
			break;
		case CTLMBCHAR:
			c = (signed char)*p--;
			mb = mbnext(p);
			ml = (mb >> 8) - 2;
			if (flag & (QUOTES_ESC | EXP_MBCHAR)) {
				length = (mb >> 8) + (mb & 0xff);
				if (c == (char)CTLESC)
					startloc += length;
				break;
			}
			if (c == CTLESC)
				startloc += ml;
			p += mb & 0xff;
			expdest = stnputs(p, ml, expdest);
			p += mb >> 8;
			break;
		case CTLESC:
			startloc++;
			length++;
			goto addquote;
		case CTLVAR:
			p = evalvar(p, flag | inquotes);
			goto start;
		case CTLBACKQ:
			expbackq(argbackq->n, flag | inquotes);
			goto start;
		case CTLARI:
			p = expari(p, flag | inquotes);
			goto start;
		}
	}
	return p - 1;
}

static char *exptilde(char *startp, int flag)
{
	signed char c;
	char *name;
	const char *home;
	char *p;

	p = startp;
	name = p + 1;

	while ((c = *++p) != '\0') {
		switch(c) {
		case CTLESC:
			return (startp);
		case CTLQUOTEMARK:
			return (startp);
		case ':':
			if (flag & EXP_VARTILDE)
				goto done;
			break;
		case '/':
		case CTLENDVAR:
			goto done;
		}
	}
done:
	if (flag & EXP_DISCARD)
		goto out;
	*p = '\0';
	if (*name == '\0') {
		home = lookupvar(homestr);
	} else {
		home = getpwhome(name);
	}
	*p = c;
	if (!home)
		goto lose;
	strtodest(home, flag | EXP_QUOTED);
out:
	return (p);
lose:
	return (startp);
}


void 
removerecordregions(int endoff)
{
	if (ifslastp == NULL)
		return;

	if (ifsfirst.endoff > endoff) {
		while (ifsfirst.next != NULL) {
			struct ifsregion *ifsp;
			INTOFF;
			ifsp = ifsfirst.next->next;
			ckfree(ifsfirst.next);
			ifsfirst.next = ifsp;
			INTON;
		}
		if (ifsfirst.begoff > endoff)
			ifslastp = NULL;
		else {
			ifslastp = &ifsfirst;
			ifsfirst.endoff = endoff;
		}
		return;
	}
	
	ifslastp = &ifsfirst;
	while (ifslastp->next && ifslastp->next->begoff < endoff)
		ifslastp=ifslastp->next;
	while (ifslastp->next != NULL) {
		struct ifsregion *ifsp;
		INTOFF;
		ifsp = ifslastp->next->next;
		ckfree(ifslastp->next);
		ifslastp->next = ifsp;
		INTON;
	}
	if (ifslastp->endoff > endoff)
		ifslastp->endoff = endoff;
}


/*
 * Expand arithmetic expression.  Backup to start of expression,
 * evaluate, place result in (backed up) result, adjust string position.
 */
static char *expari(char *start, int flag)
{
	struct stackmark sm;
	int begoff;
	int endoff;
	int len;
	intmax_t result;
	char *p;

	p = stackblock();
	begoff = expdest - p;
	p = argstr(start, flag & EXP_DISCARD);

	if (flag & EXP_DISCARD)
		goto out;

	start = stackblock();
	endoff = expdest - start;
	start += begoff;
	STADJUST(start - expdest, expdest);

	removerecordregions(begoff);

	pushstackmark(&sm, endoff);
	result = arith(start);
	popstackmark(&sm);

	len = cvtnum(result, flag);

	if (likely(!(flag & EXP_QUOTED)))
		recordregion(begoff, begoff + len, 0);

out:
	return p;
}


/*
 * Expand stuff in backwards quotes.
 */

STATIC void
expbackq(union node *cmd, int flag)
{
	struct backcmd in;
	int i;
	char buf[128];
	char *p;
	char *dest;
	int startloc;
	struct stackmark smark;

	if (flag & EXP_DISCARD)
		goto out;

	INTOFF;
	startloc = expdest - (char *)stackblock();
	pushstackmark(&smark, startloc);
#ifdef FDASH
	{
	/* the substitution may run in this shell (see evalbackcmd), and its
	 * own expansions must not take this word's state with them */
	struct nodelist *saveargbackq = argbackq;
	struct ifsregion saveifsfirst = ifsfirst;
	struct ifsregion *saveifslastp = ifslastp;

	ifsfirst.next = NULL;
	ifslastp = NULL;
	evalbackcmd(cmd, (struct backcmd *) &in);
	argbackq = saveargbackq;
	ifsfirst = saveifsfirst;
	ifslastp = saveifslastp;
	}
#else
	evalbackcmd(cmd, (struct backcmd *) &in);
#endif
	popstackmark(&smark);
#ifdef FDASH
	expdest = (char *)stackblock() + startloc;
#endif

	p = in.buf;
	i = in.nleft;
	if (i == 0)
		goto read;
	for (;;) {
		memtodest(p, i, flag);
read:
		if (in.fd < 0)
			break;
		do {
			i = read(in.fd, buf, sizeof buf);
		} while (i < 0 && errno == EINTR);
		TRACE(("expbackq: read returns %d\n", i));
		if (i <= 0)
			break;
		p = buf;
	}

	if (in.buf)
		ckfree(in.buf);
	if (in.fd >= 0) {
		close(in.fd);
		back_exitstatus = waitforjob(in.jp);
	}
	INTON;

	/* Eat all trailing newlines */
	dest = expdest;
	for (; dest > ((char *)stackblock() + startloc) && dest[-1] == '\n';)
		STUNPUTC(dest);
	expdest = dest;

	if (!(flag & EXP_QUOTED))
		recordregion(startloc, dest - (char *)stackblock(), 0);
	TRACE(("evalbackq: size=%d: \"%.*s\"\n",
		(dest - (char *)stackblock()) - startloc,
		(dest - (char *)stackblock()) - startloc,
		stackblock() + startloc));

out:
	argbackq = argbackq->next;
}


static char *scanleft(char *startp, char *endp, char *rmesc, char *rmescend,
		      char *str, int quotes, int zero
) {
	char *loc;
	char *loc2;
	char c;

	loc = startp;
	loc2 = rmesc;
	do {
		char *s = FNMATCH_IS_ENABLED ? loc2 : loc;
		unsigned mb;
		unsigned ml;
		int match;

		c = *s;
		if (zero) {
			*s = '\0';
			s = FNMATCH_IS_ENABLED ? rmesc : startp;
		}
		match = pmatch(str, s);
		*(FNMATCH_IS_ENABLED ? loc2 : loc) = c;
		if (match)
			return quotes ? loc : loc2;

		if (!c)
			break;

		mb = mbnext(loc);
		loc += (mb & 0xff) + (mb >> 8);
		ml = (mb >> 8) > 3 ? (mb >> 8) - 2 : 1;
		loc2 += ml;
	} while (1);
	return 0;
}


static char *scanright(char *startp, char *endp, char *rmesc, char *rmescend,
		       char *str, int quotes, int zero
) {
	size_t esc = 0;
	char *loc;
	char *loc2;

	for (loc = endp, loc2 = rmescend;; loc2--) {
		char *s = FNMATCH_IS_ENABLED ? loc2 : loc;
		char c = *s;
		unsigned ml;
		int match;

		if (zero) {
			*s = '\0';
			s = FNMATCH_IS_ENABLED ? rmesc : startp;
		}
		match = pmatch(str, s);
		*(FNMATCH_IS_ENABLED ? loc2 : loc) = c;
		if (match)
			return quotes ? loc : loc2;
		if (--loc < startp)
			break;
		if (!esc--)
			esc = esclen(startp, loc);
		if (esc % 2) {
			esc--;
			loc--;
			continue;
		}
		if (*loc != (char)CTLMBCHAR)
			continue;

		ml = (unsigned char)*--loc;
		loc -= ml + 2;
		if (*loc == (char)CTLESC)
			loc--;
		loc2 -= ml - 1;
	}
	return 0;
}

static char *subevalvar(char *start, char *str, int strloc, int startloc,
			int varflags, int flag)
{
	int subtype = varflags & VSTYPE;
	int quotes = flag & QUOTES_ESC;
	char *startp;
	char *loc;
	long amount;
	char *rmesc, *rmescend;
	int zero;
	char *(*scan)(char *, char *, char *, char *, char *, int , int);
	int nstrloc = strloc;
	char *endp;
	char *p;

	p = argstr(start, (flag & EXP_DISCARD) | EXP_TILDE |
			  (str ?  0 : EXP_CASE));
	if (flag & EXP_DISCARD)
		return p;

	startp = stackblock() + startloc;

	switch (subtype) {
	case VSASSIGN:
		setvar(str, startp, 0);

		loc = startp;
		goto out;

	case VSQUESTION:
		varunset(start, str, startp, varflags);
		/* NOTREACHED */
	}

	subtype -= VSTRIMRIGHT;
#ifdef DEBUG
	if (subtype < 0 || subtype > 3)
		abort();
#endif

	rmescend = stackblock() + strloc;
	str = preglob(rmescend, 0);
	if (FNMATCH_IS_ENABLED) {
		startp = stackblock() + startloc;
		rmescend = stackblock() + strloc;
		nstrloc = str - (char *)stackblock();
	}

	rmesc = startp;
	if (FNMATCH_IS_ENABLED || !quotes) {
		rmesc = _rmescapes(startp, RMESCAPE_ALLOC | RMESCAPE_GROW);
		if (rmesc != startp)
			rmescend = expdest;
		startp = stackblock() + startloc;
		str = stackblock() + nstrloc;
	}
	rmescend--;

	/* zero = subtype == VSTRIMLEFT || subtype == VSTRIMLEFTMAX */
	zero = subtype >> 1;
	/* VSTRIMLEFT/VSTRIMRIGHTMAX -> scanleft */
	scan = (subtype & 1) ^ zero ? scanleft : scanright;

	endp = stackblock() + strloc - 1;
	loc = scan(startp, endp, rmesc, rmescend, str, quotes, zero);
	if (!loc) {
		if (quotes) {
			rmesc = startp;
			rmescend = endp;
		}
	} else if (!quotes) {
		if (zero)
			rmesc = loc;
		else
			rmescend = loc;
	} else if (zero) {
		rmesc = loc;
		rmescend = endp;
	} else {
		rmesc = startp;
		rmescend = loc;
	}

	memmove(startp, rmesc, rmescend - rmesc);
	loc = startp + (rmescend - rmesc);

out:
	*loc = '\0';
	amount = loc - expdest;
	STADJUST(amount, expdest);

	/* Remove any recorded regions beyond start of variable */
	removerecordregions(startloc);

	return p;
}



#ifdef FDASH
/*
 * ksh93's and bash's ${var:offset:length}, ${var/pattern/string} and
 * ${var^^}. Each works on the plain value and plain operands, and puts the
 * result back as the context wants it: quoted, split or matched.
 */


/* The CTLENDVAR that ends the word at p, past nested expansions. With sep,
 * also the first sepc at its top level: unquoted, unescaped, not inside
 * another expansion, so a / that a variable holds is never a separator.
 * A colon is the exception: inside double quotes the parser escapes every
 * one, and the offset and length are arithmetic anyway. */
static char *fdash_wordend(char *p, int sepc, char **sep)
{
	int depth = 0;
	int inquotes = 0;

	for (;; p++) {
		switch ((signed char)*p) {
		case 0:
			return p;
		case CTLESC:
			p++;
			if (sep && !*sep && !depth && sepc == ':' && *p == ':')
				*sep = p;
			break;
		case CTLMBCHAR: {
			int j = 1;

			if ((signed char)p[j] == CTLESC)
				j++;
			p += j + (unsigned char)p[j] + 2;
			break;
		}
		case CTLVAR:
			/* $name and ${name} have no CTLENDVAR of their own */
			if ((*++p & VSTYPE) != VSNORMAL)
				depth++;
			break;
		case CTLARI:
			depth++;
			break;
		case CTLENDARI:
			depth--;
			break;
		case CTLENDVAR:
			if (!depth)
				return p;
			depth--;
			break;
		case CTLQUOTEMARK:
			inquotes ^= 1;
			break;
		default:
			if (sep && !*sep && !depth && !inquotes && *p == sepc)
				*sep = p;
		}
	}
}

/* A piece of the word, ended as argstr expects, expanded with flag into a
 * string of its own. */
static char *fdash_expandpart(const char *from, const char *to, int flag,
			      int startloc)
{
	size_t n = to - from;
	char *part = alloca(n + 2);
	char *s;

	memcpy(part, from, n);
	part[n] = CTLENDVAR;
	part[n + 1] = 0;
	argstr(part, flag);
	n = expdest - ((char *)stackblock() + startloc);
	s = ckmalloc(n + 1);
	memcpy(s, (char *)stackblock() + startloc, n);
	s[n] = 0;
	expdest = (char *)stackblock() + startloc;
	return s;
}

/* A pattern as argstr leaves it with EXP_CASE, quoted characters behind
 * CTLESC, as fnmatch reads it. Sets *glob when anything in it is special. */
char *fdash_pattern(const char *s, int *glob)
{
	char *out = ckmalloc(strlen(s) * 2 + 1);
	char *q = out;

	*glob = 0;
	for (; *s; s++) {
		int c = (signed char)*s;

		if (c == CTLQUOTEMARK)
			continue;
		if (c == CTLMBCHAR) {
			int j = 1;
			unsigned ml;

			if ((signed char)s[j] == CTLESC)
				j++;
			ml = (unsigned char)s[j++];
			memcpy(q, s + j, ml);
			q += ml;
			s += j + ml + 1;
			continue;
		}
		if (c == CTLESC) {
			if (!*++s)
				break;
			if (strchr("*?[]\\", *s))
				*q++ = '\\';
			*q++ = *s;
			continue;
		}
		if (strchr("*?[", *s))
			*glob = 1;
		if (*s == '\\' && s[1]) {
			*q++ = *s++;
			*glob = 1;
		}
		*q++ = *s;
	}
	*q = 0;
	return out;
}

/* Bytes of the character at s, at least one: the locale decides, as for ${#var}. */
static size_t fdash_charlen(const char *s, size_t n)
{
	mbstate_t mbs = {};
	size_t ml = mbrlen(s, n, &mbs);

	return ml == (size_t)-1 || ml == (size_t)-2 || ml < 1 ? 1 : ml;
}

static size_t fdash_nchars(const char *s, size_t n)
{
	size_t count = 0;

	for (size_t i = 0; i < n; i += fdash_charlen(s + i, n - i))
		count++;
	return count;
}

/* The byte where character k starts, or n. */
static size_t fdash_charat(const char *s, size_t n, intmax_t k)
{
	size_t i = 0;

	while (k-- > 0 && i < n)
		i += fdash_charlen(s + i, n - i);
	return i;
}

static int fdash_match(const char *pat, const char *s, size_t from, size_t to)
{
	char *sub = ckmalloc(to - from + 1);
	int matched;

	memcpy(sub, s + from, to - from);
	sub[to - from] = 0;
	matched = !fnmatch(pat, sub, 0);
	ckfree(sub);
	return matched;
}

/* The longest match that starts at from, or -1. */
static ssize_t fdash_longest(const char *pat, const char *s, size_t n,
			     size_t from, int to_end)
{
	size_t to = n;

	for (;;) {
		if (fdash_match(pat, s, from, to))
			return to;
		if (to_end || to == from)
			return -1;
		/* back one character */
		do
			to--;
		while (to > from && (s[to] & 0xc0) == 0x80);
	}
}

struct fdash_buf {
	char *p;
	size_t len;
	size_t size;
};

static void fdash_put(struct fdash_buf *b, const char *s, size_t n)
{
	if (b->len + n + 1 > b->size) {
		b->size = (b->len + n + 1) * 2;
		b->p = ckrealloc(b->p, b->size);
	}
	memcpy(b->p + b->len, s, n);
	b->len += n;
	b->p[b->len] = 0;
}

static void fdash_replace(struct fdash_buf *out, const char *val, size_t n,
			  char *word, int startloc)
{
	char *sep = NULL;
	char *end;
	char *pat;
	char *rep;
	char *raw;
	int all = 0, start = 0, finish = 0, glob;
	size_t replen;
	size_t i;

	if (*word == '/')
		all = 1;
	else if (*word == '#')
		start = 1;
	else if (*word == '%')
		finish = 1;
	word += all | start | finish;
	end = fdash_wordend(word, '/', &sep);
	raw = fdash_expandpart(word, sep ?: end, EXP_CASE, startloc);
	rep = sep ? fdash_expandpart(sep + 1, end, 0, startloc) : savestr("");
	pat = fdash_pattern(raw, &glob);
	ckfree(raw);
	replen = strlen(rep);

	if (!*pat) {
		/* an empty pattern only has a place at either end */
		if (finish)
			fdash_put(out, val, n);
		if (start || finish)
			fdash_put(out, rep, replen);
		if (!finish)
			fdash_put(out, val, n);
		goto done;
	}
	if (!glob) {
		/* a plain string, the common case: no matching at every place */
		char *lit = ckmalloc(strlen(pat) + 1);
		size_t litlen;
		char *q = lit;

		for (const char *s = pat; *s; s++) {
			if (*s == '\\' && s[1])
				s++;
			*q++ = *s;
		}
		*q = 0;
		litlen = strlen(lit);
		i = 0;
		for (;;) {
			const char *hit = memmem(val + i, n - i, lit, litlen);

			if (start && hit != val)
				hit = NULL;
			if (finish) {
				hit = n >= litlen && !memcmp(val + n - litlen, lit, litlen) ?
				      val + n - litlen : NULL;
			}
			if (!hit) {
				fdash_put(out, val + i, n - i);
				break;
			}
			fdash_put(out, val + i, hit - (val + i));
			fdash_put(out, rep, replen);
			i = hit - val + litlen;
			if (!all) {
				fdash_put(out, val + i, n - i);
				break;
			}
		}
		ckfree(lit);
		goto done;
	}
	i = 0;
	while (i <= n) {
		ssize_t to = -1;

		if (finish) {
			/* the longest tail that matches */
			for (size_t from = 0; from <= n; from += from < n ? fdash_charlen(val + from, n - from) : 1) {
				if (fdash_match(pat, val, from, n)) {
					fdash_put(out, val, from);
					fdash_put(out, rep, replen);
					goto done;
				}
			}
			fdash_put(out, val, n);
			goto done;
		}
		to = fdash_longest(pat, val, n, i, 0);
		if (to >= 0) {
			fdash_put(out, rep, replen);
			if (!all) {
				fdash_put(out, val + to, n - to);
				goto done;
			}
			if ((size_t)to > i) {
				i = to;
				continue;
			}
		}
		if (start) {
			fdash_put(out, val + i, n - i);
			goto done;
		}
		if (i == n)
			break;
		{
			size_t ml = fdash_charlen(val + i, n - i);

			fdash_put(out, val + i, ml);
			i += ml;
		}
	}
done:
	ckfree(pat);
	ckfree(rep);
}

static void fdash_case(struct fdash_buf *out, const char *val, size_t n,
		       const char *word)
{
	/* inside double quotes the parser escapes each ^ */
	const char *op = word + ((signed char)*word == CTLESC);
	const char *next = op + 1 + ((signed char)op[1] == CTLESC);
	int upper = *op == '^';
	int every = *next == *op;
	size_t i = 0;

	while (i < n) {
		mbstate_t mbs = {};
		wchar_t wc;
		size_t ml = mbrtowc(&wc, val + i, n - i, &mbs);
		char buf[MB_LEN_MAX];
		size_t bl;

		if (ml == (size_t)-1 || ml == (size_t)-2 || ml < 1) {
			fdash_put(out, val + i, 1);
			i++;
		} else {
			mbs = (mbstate_t){};
			bl = wcrtomb(buf, upper ? towupper(wc) : towlower(wc), &mbs);
			if (bl == (size_t)-1)
				fdash_put(out, val + i, ml);
			else
				fdash_put(out, buf, bl);
			i += ml;
		}
		if (!every) {
			fdash_put(out, val + i, n - i);
			break;
		}
	}
}

static void fdash_substr(struct fdash_buf *out, const char *val, size_t n,
			 char *word, int startloc)
{
	char *sep = NULL;
	char *end = fdash_wordend(word, ':', &sep);
	/* an escaped colon ends the offset at its CTLESC */
	char *first = !sep ? end : sep > word && (signed char)sep[-1] == CTLESC ? sep - 1 : sep;
	char *text = fdash_expandpart(word, first, 0, startloc);
	intmax_t chars = fdash_nchars(val, n);
	intmax_t offset = *text ? arith(text) : 0;
	intmax_t length = chars;
	size_t from, to;

	ckfree(text);
	if (sep) {
		text = fdash_expandpart(sep + 1, end, 0, startloc);
		length = *text ? arith(text) : 0;
		ckfree(text);
	}
	if (offset < 0)
		offset += chars;
	if (offset < 0 || offset > chars)
		return;
	if (length < 0) {
		length += chars - offset;
		if (length < 0)
			sh_error("%jd: substring expression < 0", length - chars + offset);
	}
	from = fdash_charat(val, n, offset);
	to = from + fdash_charat(val + from, n - from, length);
	fdash_put(out, val + from, to - from);
}

static char *fdash_subevalvar(char *p, char *var, int startloc, int varflags,
			      int flag)
{
	int subtype = varflags & VSTYPE;
	struct fdash_buf val = { 0 }, out = { 0 };
	char *end;

	if (flag & EXP_DISCARD)
		return argstr(p, EXP_DISCARD);
	if ((*var == '@' || *var == '*') && subtype == VSSUBSTR)
		sh_error("${%c:...}: a slice of the parameters is not supported", *var);
	end = fdash_wordend(p, 0, NULL);

	/* the value with nothing escaped, whatever the context wants */
	expdest = (char *)stackblock() + startloc;
	varvalue(var, varflags, 0);
	fdash_put(&val, (char *)stackblock() + startloc,
		  expdest - ((char *)stackblock() + startloc));
	expdest = (char *)stackblock() + startloc;
	fdash_put(&out, "", 0);

	switch (subtype) {
	case VSSUBSTR:
		fdash_substr(&out, val.p, val.len, p, startloc);
		break;
	case VSREPLACE:
		fdash_replace(&out, val.p, val.len, p, startloc);
		break;
	case VSCASE:
		fdash_case(&out, val.p, val.len, p);
		break;
	}
	memtodest(out.p, out.len, flag);
	ckfree(val.p);
	ckfree(out.p);
	removerecordregions(startloc);
	return end + 1;
}
#endif

/*
 * Expand a variable, and return a pointer to the next character in the
 * input string.
 */
STATIC char *
evalvar(char *p, int flag)
{
	int subtype;
	int varflags;
	char *var;
	int patloc;
	int startloc;
	ssize_t varlen;
	int discard;
	int quoted;
	int mbchar;

	varflags = *p++ & ~VSBIT;
	subtype = varflags & VSTYPE;

	quoted = flag & EXP_QUOTED;
	var = p;
	startloc = expdest - (char *)stackblock();
	p = strchr(p, '=') + 1;

	mbchar = 0;
	switch (subtype) {
	case VSTRIMLEFT:
	case VSTRIMLEFTMAX:
	case VSTRIMRIGHT:
	case VSTRIMRIGHTMAX:
		mbchar = EXP_MBCHAR;
		break;
	}

again:
	varlen = varvalue(var, varflags, flag | mbchar);
	if (varflags & VSNUL)
		varlen--;

	discard = varlen < 0 ? EXP_DISCARD : 0;

	switch (subtype) {
	case VSPLUS:
		discard ^= EXP_DISCARD;
		/* fall through */

	case 0:
	case VSMINUS:
		p = argstr(p, flag | EXP_TILDE | EXP_WORD |
			      (discard ^ EXP_DISCARD));
		goto record;

	case VSASSIGN:
	case VSQUESTION:
		p = subevalvar(p, var, 0, startloc, varflags,
			       (flag & ~QUOTES_ESC) |
			       (discard ^ EXP_DISCARD));

		if ((flag | ~discard) & EXP_DISCARD)
			goto record;

		varflags &= ~VSNUL;
		subtype = VSNORMAL;
		goto again;
	}

	if ((discard & ~flag) && uflag)
		varunset(p, var, 0, 0);

	if (subtype == VSLENGTH) {
		p++;
		if (flag & EXP_DISCARD)
			return p;
		cvtnum(varlen > 0 ? varlen : 0, flag);
		goto really_record;
	}

	if (subtype == VSNORMAL)
		goto record;

#ifdef FDASH
	if (subtype > VSLENGTH) {
		p = fdash_subevalvar(p, var, startloc, varflags, flag | discard);
		goto record;
	}
#endif

#ifdef DEBUG
	switch (subtype) {
	case VSTRIMLEFT:
	case VSTRIMLEFTMAX:
	case VSTRIMRIGHT:
	case VSTRIMRIGHTMAX:
		break;
	default:
		abort();
	}
#endif

	flag |= discard;
	if (!(flag & EXP_DISCARD)) {
		/*
		 * Terminate the string and start recording the pattern
		 * right after it
		 */
		STPUTC('\0', expdest);
	}

	patloc = expdest - (char *)stackblock();
	p = subevalvar(p, NULL, patloc, startloc, varflags, flag);

record:
	if ((flag | discard) & EXP_DISCARD)
		return p;

really_record:
	if (quoted) {
		quoted = *var == '@' && shellparam.nparam;
		if (!quoted)
			return p;
	}
	recordregion(startloc, expdest - (char *)stackblock(), quoted);
	return p;
}

static char *chtodest(int c, const char *syntax, char *out)
{
	if (syntax[c] == CCTL)
		USTPUTC(CTLESC, out);
	USTPUTC(c, out);

	return out;
}

struct mbpair {
	unsigned ml;
	unsigned ql;
};

static struct mbpair mbtodest(const char *p, char *q, const char *syntax,
			      size_t len)
{
	mbstate_t mbs = {};
	struct mbpair mbp;
	char *q0 = q;
	size_t ml;

	ml = mbrlen(--p, len, &mbs);
	if (ml == -2 || ml == -1 || ml < 2) {
		q = chtodest((signed char)*p, syntax, q);
		ml = 1;
		goto out;
	}

	if (syntax[CTLMBCHAR] == CCTL) {
		USTPUTC(CTLMBCHAR, q);
		USTPUTC(ml, q);
	}

	q = mempcpy(q, p, ml);

	if (syntax[CTLMBCHAR] == CCTL) {
		USTPUTC(ml, q);
		USTPUTC(CTLMBCHAR, q);
	}

out:
	mbp.ml = ml - 1;
	mbp.ql = q - q0;
	return mbp;
}

/*
 * Put a string on the stack.
 */

static size_t memtodest(const char *p, size_t len, int flags)
{
	const char *syntax;
	size_t count = 0;
	int expq;
	char *q;

	if (unlikely(!len))
		return 0;

	/* CTLMBCHAR, 2, c, c, 2, CTLMBCHAR */
	q = makestrspace(len * 3, expdest);

#if QUOTES_ESC != 0x11 || EXP_MBCHAR != 0x20 || EXP_QUOTED != 0x100
#error QUOTES_ESC != 0x11 || EXP_MBCHAR != 0x20 || EXP_QUOTED != 0x100
#endif
	expq = flags & EXP_QUOTED;
	if (likely(!(flags & (expq >> 3 | expq >> 4 | expq >> 8) &
		     (QUOTES_ESC | EXP_MBCHAR)))) {
		while (len >= 8) {
			uint64_t x = *(uint64_t *)(p + count);

			if ((x | (x - 0x0101010101010101)) &
			    0x8080808080808080)
				break;

			*(uint64_t *)(q + count) = x;

			count += 8;
			len -= 8;
		}

		q += count;
		p += count;

		syntax = flags & (QUOTES_ESC | EXP_MBCHAR) ?
			 BASESYNTAX : is_type;
	} else
		syntax = SQSYNTAX;

	for (; len; len--) {
		int c = (signed char)*p++;

		if (unlikely(!c && !(flags & EXP_KEEPNUL)))
			continue;

		count++;

		if (unlikely(c < 0)) {
			struct mbpair mbp = mbtodest(p, q, syntax, len);
			unsigned mlm;

			q += mbp.ql;
			mlm = mbp.ml;
			p += mlm;
			len -= mlm;
			continue;
		}

		q = chtodest(c, syntax, q);
	}

	expdest = q;
	return count;
}


static size_t strtodest(const char *p, int flags)
{
	size_t len = strlen(p);
	return memtodest(p, len, flags);
}



/*
 * Add the value of a specialized variable to the stack string.
 */

static ssize_t varvalue(char *name, int varflags, unsigned flags)
{
	int subtype = varflags & VSTYPE;
	unsigned long seplen;
	const char *seps;
	ssize_t len = 0;
	size_t start;
	int discard;
	char **ap;
	int num;
	char *p;
	int i;

	discard = (subtype == VSPLUS || subtype == VSLENGTH) |
		  (flags & EXP_DISCARD);

	if (unlikely(!subtype)) {
		if (discard)
			return -1;

		sh_error("Bad substitution");
	}

	flags &= discard ? ~QUOTES_ESC : ~0;
	seps = nullstr;
	seplen = flags & EXP_FULL;
	start = expdest - (char *)stackblock();

	switch (*name) {
	case '$':
		num = rootpid;
		goto numvar;
	case '?':
		num = exitstatus;
		goto numvar;
	case '#':
		num = shellparam.nparam;
		goto numvar;
	case '!':
		num = backgndpid;
		if (num == 0)
			return -1;
numvar:
		len = cvtnum(num, flags);
		break;
	case '-':
		p = makestrspace(NOPTS, expdest);
		for (i = NOPTS - 1; i >= 0; i--) {
			if (optlist[i] && optletters[i]) {
				USTPUTC(optletters[i], p);
				len++;
			}
		}
		expdest = p;
		break;
	case '@':
		if ((flags & (EXP_QUOTED | EXP_FULL)) ==
		    (EXP_QUOTED | EXP_FULL))
			goto param;
		/* fall through */
	case '*':
		/* We will set seplen to 0 or !0 depending on whether
		 * we're doing field splitting.  We won't do field
		 * splitting if either we're quoted or seplen is zero.
		 *
		 * Instead of testing (quoted || !sep) the following
		 * trick optimises away any branches by using the
		 * fact that EXP_QUOTED (which is the only bit that
		 * can be set in quoted) is the same as EXP_FULL <<
		 * CHAR_BIT (which is the only bit that can be set
		 * in sep).
		 */
#if EXP_QUOTED >> CHAR_BIT != EXP_FULL
#error The following two lines expect EXP_QUOTED == EXP_FULL << CHAR_BIT
#endif
		seplen &= ~(flags >> CHAR_BIT);
		if (!seplen)
			seps = ncifs;
		seplen = ((seplen - 1) & (ifsmb0len - 1)) + 1;
param:
		if (!(ap = shellparam.p))
			return -1;
		if (!(p = *ap))
			break;
		for (;;) {
			len += strtodest(p, flags);

			if (!(p = *++ap))
				break;

			len += memtodest(seps, seplen, flags | EXP_KEEPNUL);
		}
		break;
	case '0':
	case '1':
	case '2':
	case '3':
	case '4':
	case '5':
	case '6':
	case '7':
	case '8':
	case '9':
		num = atoi(name);
		if (num < 0 || num > shellparam.nparam)
			return -1;
		p = num ? shellparam.p[num - 1] : arg0;
		goto value;
	default:
		p = lookupvar(name);
value:
		if (!p)
			return -1;

		len = strtodest(p, flags);
		break;
	}

	if (discard)
		expdest = (char *)stackblock() + start;

	return len;
}



/*
 * Record the fact that we have to scan this region of the
 * string for IFS characters.
 */

void
recordregion(int start, int end, int nulonly)
{
	struct ifsregion *ifsp;

	if (ifslastp == NULL) {
		ifsp = &ifsfirst;
	} else {
		INTOFF;
		ifsp = (struct ifsregion *)ckmalloc(sizeof (struct ifsregion));
		ifsp->next = NULL;
		ifslastp->next = ifsp;
		INTON;
	}
	ifslastp = ifsp;
	ifslastp->begoff = start;
	ifslastp->endoff = end;
	ifslastp->nulonly = nulonly;
}

static unsigned ifsisifs(const char *p, unsigned ml, const char *ifs)
{
	bool isdefifs = false;
	bool isifs = false;
	wchar_t wc = *p;
	wchar_t ifs0;

	if (likely(ifs[0]) && unlikely(wcifs)) {
		if (wc & 0x80) {
			mbstate_t mbst = {};
			wchar_t wc2;

			if (mbrtowc(&wc2, p, ml, &mbst) != ml)
				goto out;
			wc = wc2;
		}

		isifs = wcschr(wcifs, wc);
		ifs0 = wcifs[0];
	} else if (likely(!ml)) {
		isifs = strchr(ifs, wc);
		ifs0 = ifs[0];
	}

	if (isifs)
		isdefifs = iswspace(wc ?: ifs0);

out:
	return isifs << 1 | isdefifs;
}

static char *ifsbreakup_slow(struct ifs_state *ifst, struct arglist *arglist,
			     int nulonly, char *p)
{
	struct strlist *sp;
	unsigned ifschar;
	unsigned sisifs;
	bool isdefifs;
	unsigned ml;
	bool isifs;
	char *q;

	q = p;

	ifschar = mbnext(p);
	p += ifschar & 0xff;
	ml = (ifschar >> 8) > 3 ?
	     (ifschar >> 8) - 2 : 0;

	sisifs = ifsisifs(p, ml, ifst->ifs);
	p += ifschar >> 8;

	isifs = sisifs >> 1;
	isdefifs = sisifs & 1;

	/* If only reading one more argument:
	 * If we have exactly one field,
	 * read that field without its terminator.
	 * If we have more than one field,
	 * read all fields including their terminators,
	 * except for trailing IFS whitespace.
	 *
	 * This means that if we have only IFS
	 * characters left, and at most one
	 * of them is non-whitespace, we stop
	 * reading here.
	 * Otherwise, we read all the remaining
	 * characters except for trailing
	 * IFS whitespace.
	 *
	 * In any case, r indicates the start
	 * of the characters to remove, or NULL
	 * if no characters should be removed.
	 */
	if (!ifst->maxargs) {
		if (isdefifs) {
			if (!ifst->r)
				ifst->r = q;
			return p;
		}

		if (!(isifs && ifst->ifsspc))
			ifst->r = NULL;
	} else if (ifst->ifsspc) {
		if (isifs)
			q = p;

		ifst->start = q;

		if (isdefifs)
			return p;
	} else if (isifs) {
		int ifsspc = ifst->ifsspc;

		if (!nulonly) {
			ifsspc = isdefifs;
			ifst->ifsspc = ifsspc;
		}

		/* Ignore IFS whitespace at start */
		if (q == ifst->start && ifsspc) {
			ifst->start = p;
			goto out_zero_ifsspc;
		}
		if (ifst->maxargs > 0 && !--ifst->maxargs) {
			ifst->r = q;
			return p;
		}
		*q = '\0';
		sp = (struct strlist *)stalloc(sizeof *sp);
		sp->text = ifst->start;
		*arglist->lastp = sp;
		arglist->lastp = &sp->next;
		ifst->start = p;
		return p;
	}

out_zero_ifsspc:
	ifst->ifsspc = 0;
	return p;
}

/*
 * Break the argument string into pieces based upon IFS and add the
 * strings to the argument list.  The regions of the string to be
 * searched for IFS characters have been stored by recordregion.
 * If maxargs is non-negative, at most maxargs arguments will be created, by
 * joining together the last arguments.
 */
void
ifsbreakup(char *string, int maxargs, struct arglist *arglist)
{
	struct ifsregion *ifsp;
	struct ifs_state ifst;
	const char *realifs;
	struct strlist *sp;
	int nulonly;
	char *p;

	ifst.r = NULL;
	ifst.start = string;
	ifst.maxargs = maxargs;
	if (ifslastp != NULL) {
		ifst.ifsspc = 0;
		nulonly = 0;
		realifs = ncifs;
		ifsp = &ifsfirst;
		do {
			int afternul;

			p = string + ifsp->begoff;
			afternul = nulonly;
			nulonly = ifsp->nulonly;
			ifst.ifs = nulonly ? nullstr : realifs;
			ifst.ifsspc = 0;
			for (;;) {
				char *p0 = p;

				while (string + ifsp->endoff - p >= 8) {
					union {
						uint64_t qw;
						unsigned char b[8];
					} x;

					x.qw = *(uint64_t *)p;

					if ((x.qw & 0x8080808080808080))
						break;
					if (ifsmap[x.b[0]] |
					    ifsmap[x.b[1]] |
					    ifsmap[x.b[2]] |
					    ifsmap[x.b[3]] |
					    ifsmap[x.b[4]] |
					    ifsmap[x.b[5]] |
					    ifsmap[x.b[6]] |
					    ifsmap[x.b[7]])
						break;
					p += 8;
				}

				if (p != p0) {
					if (!ifst.maxargs)
						ifst.r = NULL;
					else if (ifst.ifsspc)
						ifst.start = p0;
					ifst.ifsspc = 0;
				}

				if (p >= string + ifsp->endoff)
					break;

				p = ifsbreakup_slow(&ifst, arglist,
						    afternul | nulonly, p);
			}
		} while ((ifsp = ifsp->next) != NULL);
		if (nulonly)
			goto add;
		if (ifst.r)
			*ifst.r = '\0';
	}

	if (!*ifst.start)
		return;

add:
	sp = (struct strlist *)stalloc(sizeof *sp);
	sp->text = ifst.start;
	*arglist->lastp = sp;
	arglist->lastp = &sp->next;
}

void ifsfree(void)
{
	struct ifsregion *p = ifsfirst.next;

	if (!p)
		goto out;

	INTOFF;
	do {
		struct ifsregion *ifsp;
		ifsp = p->next;
		ckfree(p);
		p = ifsp;
	} while (p);
	ifsfirst.next = NULL;
	INTON;

out:
	ifslastp = NULL;
}

void changeifs(const char *ifs)
{
	mbstate_t mbs = {};
	wchar_t *nwcifs;
	unsigned mb = 0;
	size_t len = 0;
	const char *p;
	size_t ml;

	if (!ifsset())
		ifs = defifs;
	ncifs = ifs;

	memset(ifsmap, 0, sizeof(ifsmap));

	for (p = ifs;; p++) {
		unsigned c = (unsigned char)*p;

		mb |= c >> 7;
		if (!(c >> 7))
			ifsmap[c] = 1;

		if (c == 0)
			break;

		len++;
	}

	nwcifs = NULL;

	ifsmb0len = !!len;

	if (!mb)
		goto out;

	ml = mbrlen(ifs, len, &mbs);
	if (ml == -2 || ml == -1)
		ml = 1;
	ifsmb0len = ml;

	nwcifs = ckmalloc((len + 1) * sizeof(*wcifs));
	memset(nwcifs, 0, (len + 1) * sizeof(*wcifs));

	p = ifs;
	mbsrtowcs(nwcifs, &p, len + 1, &mbs);

out:
	ckfree(wcifs);
	wcifs = nwcifs;
}

/*
 * Expand shell metacharacters.  At this point, the only control characters
 * should be escapes.  The results are stored in the list exparg.
 */

#ifdef __GLIBC__
static void *opendir_interruptible(const char *pathname)
{
	if (int_pending()) {
		suppressint = 0;
		onint();
	}

	return opendir(pathname);
}
#else
#define GLOB_ALTDIRFUNC 0
#endif

static void expandmeta_glob(struct strlist *str)
{
	while (str) {
		const char *p;
		glob64_t pglob;
		int i;

		if (fflag)
			goto nometa;

#ifdef __GLIBC__
		pglob.gl_closedir = (void *)closedir;
		pglob.gl_readdir = (void *)readdir64;
		pglob.gl_opendir = opendir_interruptible;
		pglob.gl_lstat = lstat64;
		pglob.gl_stat = stat64;
#endif

		INTOFF;
		p = preglob(str->text, RMESCAPE_HEAP);
		i = glob64(p, GLOB_ALTDIRFUNC | GLOB_NOMAGIC, 0, &pglob);
		if (p != str->text)
			ckfree(p);
		switch (i) {
		case 0:
			if ((pglob.gl_flags & (GLOB_NOMAGIC | GLOB_NOCHECK)) ==
			    (GLOB_NOMAGIC | GLOB_NOCHECK))
				goto nometa2;
			addglob(&pglob);
			globfree64(&pglob);
			INTON;
			break;
		case GLOB_NOMATCH:
nometa2:
			globfree64(&pglob);
			INTON;
nometa:
			*exparg.lastp = str;
			rmescapes(str->text);
			exparg.lastp = &str->next;
			break;
		default:	/* GLOB_NOSPACE */
			sh_error("Out of space");
		}
		str = str->next;
	}
}


/*
 * Add the result of glob(3) to the list.
 */

static void addglob(const glob64_t *pglob)
{
	char **p = pglob->gl_pathv;

	do {
		addfname(*p);
	} while (*++p);
}

STATIC void
expandmeta(struct strlist *str)
{
	/* TODO - EXP_REDIR */

	if (GLOB_IS_ENABLED)
		return expandmeta_glob(str);

	while (str) {
		struct strlist **savelastp;
		struct strlist *sp;
		char *p;
		unsigned len;

		if (fflag)
			goto nometa;
		if (!strpbrk(str->text, "*?]") || !strcmp(str->text, "]"))
			goto nometa;
		savelastp = exparg.lastp;

		INTOFF;
		p = preglob(str->text, RMESCAPE_ALLOC | RMESCAPE_HEAP);
		len = strlen(p);

		expmeta(p, len, 0);
		if (p != str->text)
			ckfree(p);
		INTON;
		if (exparg.lastp == savelastp) {
			/*
			 * no matches
			 */
nometa:
			*exparg.lastp = str;
			rmescapes(str->text);
			exparg.lastp = &str->next;
		} else {
			*exparg.lastp = NULL;
			*savelastp = sp = expsort(*savelastp);
			while (sp->next != NULL)
				sp = sp->next;
			exparg.lastp = &sp->next;
		}
		str = str->next;
	}
}

static void addfname_common(char *name)
{
	struct strlist *sp;

	sp = (struct strlist *)stalloc(sizeof *sp);
	sp->text = name;
	*exparg.lastp = sp;
	exparg.lastp = &sp->next;
}

static char *addfnamealt(char *enddir, size_t expdir_len)
{
	char *name;

	name = grabstackstr(enddir);
	addfname_common(name);

	STARTSTACKSTR(enddir);
	return stnputs(name, expdir_len, enddir) - expdir_len;
}

static char *expmeta_rmescapes(char *enddir, const char *name)
{
	const char *p;

	if (!FNMATCH_IS_ENABLED)
		return strchrnul(rmescapes(strcpy(enddir, name)), 0);

	p = name;
	do {
		char *q = strchrnul(p, '\\');

		enddir = mempcpy(enddir, p, q - p + 1);
		p = q;
		if (!*p)
			break;
		if (*++p)
			enddir[-1] = *p++;
	} while (1);

	return enddir - 1;
}

#ifndef HAVE_MEMRCHR
static void *memrchr(const void *s, int c, size_t n)
{
	const unsigned char *str = s;
	const unsigned char *cp;

	for (cp = str + n - 1; cp >= str; cp--)
		if (*cp == c)
			return cp;
	return NULL;
}
#endif

/*
 * Do metacharacter (i.e. *, ?, [...]) expansion.
 */

static char *expmeta(char *name, unsigned name_len, size_t expdir_len)
{
	const char mesc = FNMATCH_IS_ENABLED ? '\\' : CTLESC;
	struct jmploc *volatile savehandler;
	struct jmploc jmploc;
	struct stat64 statb;
	struct dirent64 *dp;
	volatile int err;
	char *endname;
	char *zeroedp;
	char *enddir;
	int matchdot;
	unsigned esc;
	char *start;
	size_t len;
	DIR *dirp;
	char *pat;
	char *cp;
	char *p;
	int c;

	*(DIR *volatile *)&dirp = NULL;
	savehandler = handler;
	if (unlikely(err = setjmp(jmploc.loc)))
		goto out;

	len = expdir_len + name_len + 1;
	cp = growstackto(len);
	enddir = cp + expdir_len;

	p = name;
	esc = 0;
	do {
		p = strpbrk(p + esc, "*?]");
		if (!p)
			break;
		esc = mesclen(name, p, mesc) & 1;
	} while (esc);
	/* No meta characters */
	if (likely(!p)) {
		if (!expdir_len)
			goto out_opendir;
		enddir = expmeta_rmescapes(enddir, name);
		if (lstat64(cp, &statb) >= 0)
			cp = addfnamealt(enddir, expdir_len);
		goto out_opendir;
	}
	start = memrchr(name, '/', p - name);
	if (start) {
		c = *++start;
		*start = 0;
		enddir = expmeta_rmescapes(enddir, name);
		*start = c;
		expdir_len = enddir - cp;
	} else
		start = name;
	*enddir = 0;

	*(DIR *volatile *)&dirp = opendir(expdir_len ? cp : dotdir);
	if (!dirp)
		goto out_opendir;
	esc = 0;
	p = strchrnul(p + 1, '/');
	zeroedp = p;
	endname = p;
	if (*p) {
		esc = mesclen(name, p, mesc) & 1;
		zeroedp -= esc;
		endname++;
	}
	c = *zeroedp;
	*zeroedp = '\0';
	name_len -= endname - name;
	matchdot = 0;
	pat = start;
	p = pat;
	if (*p == mesc)
		p++;
	if (*p == '.')
		matchdot++;
	while ((dp = readdir64(dirp))) {
		char *dname = dp->d_name;

		if (*dname == '.' && !matchdot)
			goto check_int;
		if (c && dp->d_type != DT_DIR && dp->d_type != DT_LNK &&
		    dp->d_type != DT_UNKNOWN)
			goto check_int;
		len = strlen(dname) + 1;
		p = dname;
		if (!FNMATCH_IS_ENABLED) {
			expdest = enddir;
			memtodest(p, len, EXP_MBCHAR | EXP_KEEPNUL);
			cp = stackblock();
			enddir = cp + expdir_len;
			p = enddir;
		}
		if (pmatch(pat, p)) {
			enddir = stnputs(dname, len, enddir);
			if (!c)
				cp = addfnamealt(enddir, expdir_len);
			else {
				enddir[-1] = '/';
				len += expdir_len;
				cp = expmeta(endname, name_len, len);
			}
			enddir = cp + expdir_len;
		}
check_int:
		if (int_pending())
			break;
	}
	*zeroedp = c;

out:
	closedir(*(DIR *volatile *)&dirp);
out_opendir:
	handler = savehandler;
	if (err)
		longjmp(handler->loc, 1);
	return cp;
}


/*
 * Add a file name to the list.
 */

STATIC void
addfname(char *name)
{
	addfname_common(sstrdup(name));
}


/*
 * Sort the results of file name expansion.  It calculates the number of
 * strings to sort and then calls msort (short for merge sort) to do the
 * work.
 */

STATIC struct strlist *
expsort(struct strlist *str)
{
	int len;
	struct strlist *sp;

	len = 0;
	for (sp = str ; sp ; sp = sp->next)
		len++;
	return msort(str, len);
}


STATIC struct strlist *
msort(struct strlist *list, int len)
{
	struct strlist *p, *q = NULL;
	struct strlist **lpp;
	int half;
	int n;

	if (len <= 1)
		return list;
	half = len >> 1;
	p = list;
	for (n = half ; --n >= 0 ; ) {
		q = p;
		p = p->next;
	}
	q->next = NULL;			/* terminate first half of list */
	q = msort(list, half);		/* sort first half of list */
	p = msort(p, len - half);		/* sort second half */
	lpp = &list;
	for (;;) {
		if (strcoll(p->text, q->text) < 0) {
			*lpp = p;
			lpp = &p->next;
			if ((p = *lpp) == NULL) {
				*lpp = q;
				break;
			}
		} else {
			*lpp = q;
			lpp = &q->next;
			if ((q = *lpp) == NULL) {
				*lpp = p;
				break;
			}
		}
	}
	return list;
}


/*
 * Returns true if the pattern matches the string.
 */

STATIC inline int
patmatch(char *pattern, const char *string)
{
	return pmatch(preglob(pattern, 0), string);
}


static __attribute__((noinline)) int ccmatch(char *p, const char *mbc, int ml,
					     char **r)
{
	mbstate_t mbst = {};
	wctype_t type;
	wchar_t wc;
	char *q;

	*r = 0;

	if (*p++ != ':')
		return 0;

	q = strstr(p, ":]");
	if (!q)
		return 0;

	*q = 0;
	type = wctype(p);
	*q = ':';

	if (!type)
		return 0;

	*r = q + 2;

	if (mbrtowc(&wc, mbc, ml, &mbst) != ml)
		return 0;

	return iswctype(wc, type);
}

static int pmatch(char *pattern, const char *string)
{
	const char *q;
	unsigned mb;
	char *p;
	char c;

	if (FNMATCH_IS_ENABLED)
		return !fnmatch(pattern, string, 0);

	p = pattern;
	q = string;
	for (;;) {
		switch ((signed char)(c = *p++)) {
		case '\0':
			goto breakloop;
		case CTLESC:
			c = *p++;
			break;
		case '?':
			if (*q == '\0')
				return 0;
			mb = mbnext(q);
			q += (mb >> 8) + (mb & 0xff);
			continue;
		case '*':
			c = *p;
			while (c == '*')
				c = *++p;
			if (!c)
				return 1;
			if (c == '?' || c != '[')
				c = CTLESC;
			for (;;) {
				if (c != CTLESC) {
					/* Stop should be null-terminated
					 * as it is passed as a string to
					 * strpbrk(3).
					 */
					const char stop[] = {
						c, CTLESC, CTLMBCHAR, 0,
					};
					q = strpbrk(q, stop);
					if (!q)
						return 0;
				}
				if (pmatch(p, q))
					return 1;
				if (!*q)
					break;
				mb = mbnext(q);
				q += (mb >> 8) + (mb & 0xff);
			}
			return 0;
		case '[': {
			char *startp;
			int invert, found;
			char chr;

			startp = p;
			invert = 0;
			if (*p == '!' || *p == '^') {
				invert++;
				p++;
			}
			found = 0;
			mb = mbnext(q);
			q += mb & 0xff;
			mb >>= 8;
			chr = *q;
			if (chr == '\0')
				return 0;
			c = *p++;
			do {
				unsigned mbp = 0;
				const char *mbs = &c;

				if (!c) {
					p = startp;
					c = '[';
					goto dft;
				}
				if (c == '[') {
					char *r;

					found |= !!ccmatch(p, q, mb > 1 ?
								 mb - 2 : mb,
							   &r);
					if (r) {
						p = r;
						continue;
					}
				} else if (c == (char)CTLESC)
					c = *p++;
				else if (c == (char)CTLMBCHAR) {
					mbp = mbnext(--p);
					p += mbp & 0xff;
					mbs = p;
					mbp >>= 8;
					p += mbp;
				}
				if (*p == '-' && p[1] && p[1] != ']') {
					p++;
					if (*p == (char)CTLESC)
						p++;
					else if (*p == CTLMBCHAR) {
						mbp = mbnext(p);
						p += mbp & 0xff;
						p += mbp >> 8;
						continue;
					}
					if (!(mbp | (mb - 1)) &&
					    chr >= c && chr <= *p)
						found = 1;
					p++;
				} else if (!strncmp(mbs, q, mb))
					found = 1;
			} while ((c = *p++) != ']');
			if (found == invert)
				return 0;
			q += mb;
			continue;
		}
		case CTLMBCHAR:
			mb = mbnext(--p);
			p += mb & 0xff;
			mb = mbnext(q);
			q += mb & 0xff;
			mb >>= 8;

			if (strncmp(p - 1, q - 1, mb + 1))
				return 0;

			p += mb;
			q += mb;
			continue;
		}
dft:
		mb = mbnext(q);
		if ((mb >> 8) > 1)
			return 0;
		q += mb & 0xff;
		if (*q != c)
			return 0;
		q += mb >> 8;
	}
breakloop:
	if (*q != '\0')
		return 0;
	return 1;
}



/*
 * Remove any CTLESC characters from a string.
 */

char *
_rmescapes(char *str, int flag)
{
	char *p, *q, *r;
	int notescaped;
	int globbing;
	int inquotes;

	p = strpbrk(str, cqchars);
	if (!p) {
		return str;
	}
	q = p;
	r = str;
	globbing = flag & RMESCAPE_GLOB;

	if (flag & RMESCAPE_ALLOC) {
		size_t len = p - str;
		size_t fulllen = strlen(p);

		if (FNMATCH_IS_ENABLED && globbing)
			fulllen *= 2;

		fulllen += len + 1;

		if (flag & RMESCAPE_GROW) {
			int strloc = str - (char *)stackblock();

			r = makestrspace(fulllen, expdest);
			str = (char *)stackblock() + strloc;
			p = str + len;
		} else if (flag & RMESCAPE_HEAP) {
			r = ckmalloc(fulllen);
		} else {
			r = stalloc(fulllen);
		}
		q = r;
		if (len > 0) {
			q = mempcpy(q, str, len);
		}
	}
	inquotes = 0;
	notescaped = globbing;
	while (*p) {
		int c = (signed char)*p;
		int newnesc = globbing;
		unsigned mb;
		unsigned ml;

		if (c == CTLQUOTEMARK) {
			p++;
			inquotes ^= globbing;
			continue;
		} else if (c == '\\') {
			/* naked back slash */
			newnesc ^= notescaped;
			/* naked backslashes can only occur outside quotes */
			inquotes = 0;
			if (!FNMATCH_IS_ENABLED && notescaped)
				c = CTLESC;
		} else if (c == CTLESC) {
			if ((notescaped ^ inquotes) & inquotes) {
				if (FNMATCH_IS_ENABLED)
					*q++ = '\\';
				else
					q[-1] = '\\';
			}
			if (globbing)
				*q++ = FNMATCH_IS_ENABLED ? '\\' : CTLESC;

			c = *++p;
		} else if (c == CTLMBCHAR) {
			unsigned tail = 2;

			if (!FNMATCH_IS_ENABLED && (globbing ^ notescaped))
				q--;

			mb = mbnext(p);
			ml = mb >> 8;

			if (!globbing || FNMATCH_IS_ENABLED) {
				p += mb & 0xff;
				ml -= 2;
			} else {
				ml += mb & 0xff;
				tail = 0;
			}

			q = mempcpy(q, p, ml);
			p += ml + tail;
			goto setnesc;
		}

		*q++ = c;
		p++;
setnesc:
		notescaped = newnesc;
	}
	if (!FNMATCH_IS_ENABLED && (globbing ^ notescaped))
		q[-1] = '\\';
	*q = '\0';
	if (flag & (RMESCAPE_ALLOC | RMESCAPE_GROW)) {
		expdest = r;
		STADJUST(q - r + 1, expdest);
	}
	return r;
}



/*
 * See if a pattern matches in a case statement.
 */

int
casematch(union node *pattern, char *val)
{
	struct stackmark smark;
	int result;

	setstackmark(&smark);
	argbackq = pattern->narg.backquote;
	STARTSTACKSTR(expdest);
	argstr(pattern->narg.text, EXP_TILDE | EXP_CASE);
	ifsfree();
	result = patmatch(stackblock(), val);
	popstackmark(&smark);
	return result;
}

/*
 * Our own itoa().
 */

static size_t cvtnum(intmax_t num, int flags)
{
	int len = max_int_length(sizeof(num));
	char buf[len];

	len = fmtstr(buf, len, "%" PRIdMAX, num);
	return memtodest(buf, len, flags);
}

STATIC void
varunset(const char *end, const char *var, const char *umsg, int varflags)
{
	const char *msg;
	const char *tail;

	tail = nullstr;
	msg = "parameter not set";
	if (umsg) {
		if (*end == (char)CTLENDVAR) {
			if (varflags & VSNUL)
				tail = " or null";
		} else
			msg = umsg;
	}
	sh_error("%.*s: %s%s", end - var - 1, var, msg, tail);
}

void restore_handler_expandarg(struct jmploc *savehandler, int err)
{
	handler = savehandler;
	if (err) {
		if (exception != EXERROR)
			longjmp(handler->loc, 1);
		ifsfree();
	}
}

#ifdef mkinit

INCLUDE "expand.h"

EXITRESET {
	ifsfree();
}

#endif
