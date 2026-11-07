/* ksh93's [[ ]] for fdash. SPDX-License-Identifier: GPL-3.0-or-later */

#include <fnmatch.h>
#include <regex.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "shell.h"
#include "nodes.h"
#include "expand.h"
#include "memalloc.h"
#include "error.h"
#include "var.h"
#include "parser.h"
#include "builtins.h"
#include "redir.h"
#include "fdash.h"

/* dash's test builtin, for the file tests, and eval.c's redirections */
int testcmd(int, char **);
void fdash_expredir(union node *);

/*
 * The words of [[ ]] are expanded without splitting or globbing, and kept two
 * ways: plain, and with what was quoted marked, so that the right side of ==
 * and =~ matches what was quoted literally. All are expanded before any is
 * evaluated, unlike ksh93, which matters only for a $(...) on the side of an
 * && that is not taken.
 */
struct dbx {
	char **plain;
	char **escaped;
	int n;
	int i;
};

static const char *peek(struct dbx *x)
{
	return x->i < x->n ? x->plain[x->i] : NULL;
}

static int at(struct dbx *x, const char *s)
{
	const char *p = peek(x);

	return p && !strcmp(p, s);
}

static int isbinary(const char *s)
{
	static const char *const ops[] = {
		"==", "=", "!=", "=~", "<", ">", "-eq", "-ne", "-lt", "-le",
		"-gt", "-ge", "-nt", "-ot", "-ef", NULL,
	};

	for (const char *const *op = ops; *op; op++)
		if (!strcmp(s, *op))
			return 1;
	return 0;
}

static int isunary(const char *s)
{
	return s[0] == '-' && s[1] && !s[2] && strchr("abcdefghknoprstuvwxzGLNOS", s[1]);
}

static int isend(const char *s)
{
	return !strcmp(s, "&&") || !strcmp(s, "||") || !strcmp(s, ")");
}

/* A regular expression from a word: what was quoted matches itself. */
static char *regexof(const char *s)
{
	char *out = ckmalloc(strlen(s) * 2 + 1);
	char *q = out;
	int inquotes = 0;

	for (; *s; s++) {
		int c = (signed char)*s;

		if (c == CTLQUOTEMARK) {
			inquotes ^= 1;
			continue;
		}
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
			inquotes |= 2;
		}
		if (inquotes && strchr(".[]()*+?{}|^$\\", *s))
			*q++ = '\\';
		inquotes &= 1;
		*q++ = *s;
	}
	*q = 0;
	return out;
}

static int matches(struct dbx *x, int left, int right)
{
	int glob;
	char *pattern = fdash_pattern(x->escaped[right], &glob);
	int matched = !fnmatch(pattern, x->plain[left], 0);

	ckfree(pattern);
	return matched;
}

static int regmatches(struct dbx *x, int left, int right)
{
	char *expr = regexof(x->escaped[right]);
	regex_t re;
	int rc = regcomp(&re, expr, REG_EXTENDED | REG_NOSUB);

	ckfree(expr);
	if (rc) {
		char msg[128];

		regerror(rc, &re, msg, sizeof(msg));
		sh_error("[[: %s: %s", x->plain[right], msg);
	}
	rc = regexec(&re, x->plain[left], 0, NULL, 0);
	regfree(&re);
	return !rc;
}

static int viatest(int argc, const char *a, const char *b, const char *c)
{
	char *argv[] = { "test", (char *)a, (char *)b, (char *)c, NULL };

	return !testcmd(argc, argv);
}

static int dbor(struct dbx *x);

static int primary(struct dbx *x)
{
	const char *t = peek(x);
	int left;

	if (!t)
		sh_error("[[: an expression is missing");
	if (!strcmp(t, "!")) {
		x->i++;
		return !primary(x);
	}
	if (!strcmp(t, "(")) {
		int r;

		x->i++;
		r = dbor(x);
		if (!at(x, ")"))
			sh_error("[[: ) is missing");
		x->i++;
		return r;
	}
	if (isunary(t) && x->i + 1 < x->n && !isend(x->plain[x->i + 1]) &&
	    !(x->i + 2 < x->n && isbinary(x->plain[x->i + 1]))) {
		const char *a = x->plain[x->i + 1];

		x->i += 2;
		switch (t[1]) {
		case 'v':
			return lookupvar(a) != NULL;
		case 'n':
			return *a != 0;
		case 'z':
			return *a == 0;
		}
		return viatest(3, t, a, NULL);
	}
	left = x->i++;
	if (peek(x) && isbinary(peek(x)) && x->i + 1 < x->n) {
		const char *op = x->plain[x->i];
		int right = x->i + 1;
		const char *a = x->plain[left], *b = x->plain[right];

		x->i += 2;
		if (!strcmp(op, "==") || !strcmp(op, "="))
			return matches(x, left, right);
		if (!strcmp(op, "!="))
			return !matches(x, left, right);
		if (!strcmp(op, "=~"))
			return regmatches(x, left, right);
		if (!strcmp(op, "<"))
			return strcoll(a, b) < 0;
		if (!strcmp(op, ">"))
			return strcoll(a, b) > 0;
		if (op[1] == 'e' && op[2] == 'q')
			return arith(a) == arith(b);
		if (op[1] == 'n' && op[2] == 'e')
			return arith(a) != arith(b);
		if (op[1] == 'l' && op[2] == 't')
			return arith(a) < arith(b);
		if (op[1] == 'l' && op[2] == 'e')
			return arith(a) <= arith(b);
		if (op[1] == 'g' && op[2] == 't')
			return arith(a) > arith(b);
		if (op[1] == 'g' && op[2] == 'e')
			return arith(a) >= arith(b);
		return viatest(4, a, op, b);
	}
	return *x->plain[left] != 0;
}

static int dband(struct dbx *x)
{
	int r = primary(x);

	while (at(x, "&&")) {
		int next;

		x->i++;
		next = primary(x);
		r = r && next;
	}
	return r;
}

static int dbor(struct dbx *x)
{
	int r = dband(x);

	while (at(x, "||")) {
		int next;

		x->i++;
		next = dband(x);
		r = r || next;
	}
	return r;
}

int fdash_evaldbracket(union node *n, int flags)
{
	struct stackmark smark;
	struct arglist list;
	struct strlist *sp;
	struct dbx x;
	int result;
	int i;

	(void)flags;
	if (n->ncmd.redirect) {
		int status;

		fdash_expredir(n->ncmd.redirect);
		pushredir(n->ncmd.redirect);
		status = redirectsafe(n->ncmd.redirect, REDIR_PUSH);
		if (status) {
			popredir(0);
			return status;
		}
	}
	setstackmark(&smark);
	list.lastp = &list.list;
	x.n = 0;
	for (union node *a = n->ncmd.args; a; a = a->narg.next) {
		expandarg(a, &list, EXP_TILDE | EXP_CASE);
		x.n++;
	}
	*list.lastp = NULL;
	x.plain = stalloc(sizeof(char *) * (x.n + 1));
	x.escaped = stalloc(sizeof(char *) * (x.n + 1));
	i = 0;
	for (sp = list.list; sp && i < x.n; sp = sp->next, i++) {
		x.escaped[i] = sp->text;
		x.plain[i] = strcpy(stalloc(strlen(sp->text) + 1), sp->text);
		rmescapes(x.plain[i]);
	}
	x.n = i;
	x.i = 0;
	if (!x.n)
		sh_error("[[: an expression is missing");
	result = dbor(&x);
	if (x.i < x.n)
		sh_error("[[: unexpected %s", x.plain[x.i]);
	popstackmark(&smark);
	if (n->ncmd.redirect)
		popredir(0);
	return !result;
}
