/*
 * fdash: the interactive side of fish on top of dash.
 *
 * Nothing here runs unless the shell is interactive on a terminal, so scripts
 * and `fdash -c` go through the plain dash code paths. The editing itself is
 * isocline; this file adds the shell knowledge: prompt, syntax highlighting,
 * completion, abbreviations and implicit cd.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <ctype.h>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "shell.h"
#include "alias.h"
#include "builtins.h"
#include "cd.h"
#include "error.h"
#include "eval.h"
#include "exec.h"
#include "memalloc.h"
#include "mystring.h"
#include "options.h"
#include "output.h"
#include "parser.h"
#include "var.h"

#include "isocline.h"
#include "fdash.h"
#include "util.h"

#define HISTORY_MAX 10000
#define SLOW_COMMAND_SECONDS 3

/* --------------------------------------------------------------- commands */

static const char *const keywords[] = {
	"!", "case", "do", "done", "elif", "else", "esac", "fi", "for", "if",
	"in", "then", "until", "while", "{", "}",
};

/* Everything executable on PATH, sorted; reread when PATH or a directory changes. */
static char **cmds;
static size_t ncmds;
static char *cached_path;
static time_t cached_newest;
static int cmds_stale = 1;

static int cmp_str(const void *a, const void *b)
{
	return strcmp(*(char *const *)a, *(char *const *)b);
}

static time_t path_newest(const char *path)
{
	struct sb dir = {0};
	time_t newest = 0;
	const char *p = path;

	for (;;) {
		const char *end = strchr(p, ':');
		size_t n = end ? (size_t)(end - p) : strlen(p);
		struct stat st;

		sb_clear(&dir);
		sb_add(&dir, p, n);
		if (n && stat(dir.s, &st) == 0 && st.st_mtime > newest)
			newest = st.st_mtime;
		if (!end)
			break;
		p = end + 1;
	}
	free(dir.s);
	return newest;
}

/* Called for every prompt: costs one stat per PATH directory. */
static void cmds_check(void)
{
	const char *path = pathval();
	time_t newest = path_newest(path);

	if (!cached_path || strcmp(cached_path, path) || newest != cached_newest) {
		free(cached_path);
		cached_path = strdup(path);
		cached_newest = newest;
		cmds_stale = 1;
	}
}

/* Runs on the first key press, not at startup, so the first prompt stays instant. */
static void cmds_load(void)
{
	struct sb dir = {0}, file = {0};
	const char *p = cached_path;
	size_t cap = 0, i, kept = 0;

	if (!cmds_stale || !p)
		return;
	cmds_stale = 0;
	for (i = 0; i < ncmds; i++)
		free(cmds[i]);
	ncmds = 0;
	for (;;) {
		const char *end = strchr(p, ':');
		size_t n = end ? (size_t)(end - p) : strlen(p);
		DIR *d;

		sb_clear(&dir);
		sb_add(&dir, p, n);
		if (n && (d = opendir(dir.s))) {
			struct dirent *e;

			while ((e = readdir(d))) {
				struct stat st;

				if (e->d_name[0] == '.')
					continue;
				sb_clear(&file);
				sb_str(&file, dir.s);
				sb_chr(&file, '/');
				sb_str(&file, e->d_name);
				if (stat(file.s, &st) || S_ISDIR(st.st_mode) || access(file.s, X_OK))
					continue;
				if (ncmds == cap) {
					char **nc;

					cap = cap ? cap * 2 : 1024;
					nc = realloc(cmds, cap * sizeof(*cmds));
					if (!nc)
						break;
					cmds = nc;
				}
				if ((cmds[ncmds] = strdup(e->d_name)))
					ncmds++;
			}
			closedir(d);
		}
		if (!end)
			break;
		p = end + 1;
	}
	free(dir.s);
	free(file.s);
	if (!ncmds)
		return;
	qsort(cmds, ncmds, sizeof(*cmds), cmp_str);
	for (i = 1, kept = 1; i < ncmds; i++) {
		if (strcmp(cmds[i], cmds[kept - 1]))
			cmds[kept++] = cmds[i];
		else
			free(cmds[i]);
	}
	ncmds = kept;
}

/* Index of the first command >= name. */
static size_t cmds_lower(const char *name)
{
	size_t lo = 0, hi = ncmds;

	while (lo < hi) {
		size_t mid = lo + (hi - lo) / 2;

		if (strcmp(cmds[mid], name) < 0)
			lo = mid + 1;
		else
			hi = mid;
	}
	return lo;
}

static int is_keyword(const char *word, size_t n)
{
	size_t i;

	for (i = 0; i < sizeof(keywords) / sizeof(keywords[0]); i++)
		if (strlen(keywords[i]) == n && !strncmp(keywords[i], word, n))
			return 1;
	return 0;
}

/* True for what the shell would run on its own, without implicit cd. */
static int is_runnable(const char *name)
{
	size_t i;

	if (strchr(name, '/')) {
		struct stat st;

		return stat(name, &st) == 0 && !S_ISDIR(st.st_mode) && access(name, X_OK) == 0;
	}
	if (lookupalias(name, 0) || fdash_isfunction(name) || find_builtin(name) || fdash_autoload_exists(name))
		return 1;
	cmds_load();
	i = cmds_lower(name);
	return i < ncmds && !strcmp(cmds[i], name);
}

/* ------------------------------------------------------------- tokenizing */

enum tok { T_END, T_SEP, T_REDIR, T_COMMENT, T_WORD };

struct token {
	enum tok type;
	long start, end;
};

/* Past this the rest of a line stays one word without colors: pasted text must not overrun the stack. */
#define MAX_NESTING 32

static long paren_end(const char *s, long i, long lim, int depth);

static long dquote_end(const char *s, long i, long lim, int depth)
{
	while (i < lim) {
		if (s[i] == '\\')
			i += 2;
		else if (s[i] == '"')
			return i + 1;
		else if (s[i] == '$' && i + 1 < lim && s[i + 1] == '(')
			i = depth < MAX_NESTING ? paren_end(s, i + 2, lim, depth + 1) : lim;
		else
			i++;
	}
	return lim;
}

/* i is just past an opening parenthesis; the result is just past its closer. */
static long paren_end(const char *s, long i, long lim, int depth)
{
	int open = 1;

	while (i < lim) {
		switch (s[i]) {
		case '\\':
			i += 2;
			continue;
		case '\'':
			for (i++; i < lim && s[i] != '\''; i++)
				;
			break;
		case '"':
			i = depth < MAX_NESTING ? dquote_end(s, i + 1, lim, depth + 1) : lim;
			continue;
		case '(':
			open++;
			break;
		case ')':
			if (!--open)
				return i + 1;
			break;
		}
		i++;
	}
	return lim;
}

static long word_end(const char *s, long i, long lim)
{
	while (i < lim) {
		char c = s[i];

		if (c == '\\') {
			i += 2;
		} else if (c == '\'') {
			for (i++; i < lim && s[i] != '\''; i++)
				;
			i++;
		} else if (c == '"') {
			i = dquote_end(s, i + 1, lim, 0);
		} else if (c == '`') {
			for (i++; i < lim && s[i] != '`'; i++)
				if (s[i] == '\\')
					i++;
			i++;
		} else if (c == '$' && i + 1 < lim && s[i + 1] == '(') {
			i = paren_end(s, i + 2, lim, 0);
		} else if (c == '$' && i + 1 < lim && s[i + 1] == '{') {
			for (i += 2; i < lim && s[i] != '}'; i++)
				;
			i++;
		} else if (isspace((unsigned char)c) || strchr(";&|()<>", c)) {
			return i;
		} else {
			i++;
		}
	}
	return lim;
}

static long next_token(const char *s, long i, long lim, struct token *t)
{
	long j;

	while (i < lim && (s[i] == ' ' || s[i] == '\t' || (s[i] == '\\' && i + 1 < lim && s[i + 1] == '\n')))
		i += s[i] == '\\' ? 2 : 1;
	t->start = i;
	if (i >= lim) {
		t->type = T_END;
		t->end = lim;
		return lim;
	}
	if (s[i] == '#') {
		for (j = i; j < lim && s[j] != '\n'; j++)
			;
		t->type = T_COMMENT;
		t->end = j;
		return j;
	}
	if (s[i] == '\n' || strchr(";&|()", s[i])) {
		t->type = T_SEP;
		j = i + 1;
		if (j < lim && s[j] == s[i] && strchr(";&|", s[i]))
			j++;
		t->end = j;
		return j;
	}
	for (j = i; j < lim && isdigit((unsigned char)s[j]); j++)
		;
	if (j < lim && (s[j] == '<' || s[j] == '>')) {
		j++;
		while (j < lim && strchr("<>&|-", s[j]))
			j++;
		t->type = T_REDIR;
		t->end = j;
		return j;
	}
	t->type = T_WORD;
	t->end = word_end(s, i, lim);
	if (t->end > lim)
		t->end = lim;
	return t->end;
}

/* What the next word means, tracked over the tokens of a line. */
struct state {
	int cmdpos;	/* the next word is a command */
	int redir;	/* the next word is a redirection target */
	int wrapper;	/* the previous word runs the next one (doas, exec, ...) */
};

static int is_wrapper(const char *w, size_t n)
{
	static const char *const names[] = {
		"builtin", "command", "doas", "env", "exec", "nice", "nohup", "sudo", "time", "xargs",
	};
	size_t i;

	for (i = 0; i < sizeof(names) / sizeof(names[0]); i++)
		if (strlen(names[i]) == n && !strncmp(names[i], w, n))
			return 1;
	return 0;
}

static int is_assignment(const char *w, size_t n)
{
	size_t i = 0;

	if (!n || !(isalpha((unsigned char)w[0]) || w[0] == '_'))
		return 0;
	while (i < n && (isalnum((unsigned char)w[i]) || w[i] == '_'))
		i++;
	return i < n && w[i] == '=';
}

/* Updates the state past a token. */
static void state_step(struct state *st, const char *s, const struct token *t)
{
	const char *w = s + t->start;
	size_t n = (size_t)(t->end - t->start);

	switch (t->type) {
	case T_SEP:
		st->cmdpos = 1;
		st->redir = 0;
		st->wrapper = 0;
		break;
	case T_REDIR:
		st->redir = 1;
		break;
	case T_WORD:
		if (st->redir) {
			st->redir = 0;
		} else if (st->cmdpos) {
			if (st->wrapper && *w == '-') {
				st->cmdpos = 0;	/* options may take values, stop guessing */
				st->wrapper = 0;
			} else if (is_assignment(w, n)) {
				/* stays a command position */
			} else if (is_keyword(w, n)) {
				if (!strncmp(w, "for", n) || !strncmp(w, "case", n) || !strncmp(w, "in", n)
				    || !strncmp(w, "fi", n) || !strncmp(w, "done", n) || !strncmp(w, "esac", n))
					st->cmdpos = 0;
			} else {
				st->wrapper = is_wrapper(w, n);
				st->cmdpos = st->wrapper;
			}
		}
		break;
	default:
		break;
	}
}

/*
 * The text of a word when it holds no expansion, unquoted and with the tilde
 * resolved. Returns 0 for words only known at run time.
 */
static int word_text(const char *s, long i, long end, struct sb *out)
{
	sb_clear(out);
	if (s[i] == '~' && (i + 1 == end || s[i + 1] == '/')) {
		const char *home = lookupvar("HOME");

		if (!home)
			return 0;
		sb_str(out, home);
		i++;
	}
	while (i < end) {
		char c = s[i];

		if (c == '$' || c == '`' || c == '*' || c == '?' || c == '[')
			return 0;
		if (c == '\\' && i + 1 < end) {
			sb_chr(out, s[i + 1]);
			i += 2;
		} else if (c == '\'') {
			for (i++; i < end && s[i] != '\''; i++)
				sb_chr(out, s[i]);
			i++;
		} else if (c == '"') {
			for (i++; i < end && s[i] != '"'; i++) {
				if (s[i] == '$' || s[i] == '`')
					return 0;
				if (s[i] == '\\' && i + 1 < end)
					i++;
				sb_chr(out, s[i]);
			}
			i++;
		} else {
			sb_chr(out, c);
			i++;
		}
	}
	return 1;
}

/* ----------------------------------------------------------- highlighting */

static void hl_range(ic_highlight_env_t *henv, const char *s, long i, long lim);

/* Did a scan from start end on the quote or parenthesis before j, rather than run out? */
static int closed_by(const char *s, long start, long j, char c)
{
	long k = j - 2;

	if (j <= start || s[j - 1] != c)
		return 0;
	while (k >= start && s[k] == '\\')
		k--;
	return (j - 2 - k) % 2 == 0;
}

/* The quotes and expansions inside a word; one left open shows as an error. */
static void hl_inner(ic_highlight_env_t *henv, const char *s, long i, long end)
{
	while (i < end) {
		char c = s[i];
		long j;

		if (c == '\\') {
			ic_highlight(henv, i, 2 <= end - i ? 2 : 1, "fd-escape");
			i += 2;
		} else if (c == '\'') {
			for (j = i + 1; j < end && s[j] != '\''; j++)
				;
			ic_highlight(henv, i, (j < end ? j + 1 : end) - i, "fd-string");
			if (j >= end)
				ic_highlight(henv, i, 1, "fd-error");
			i = j < end ? j + 1 : end;
		} else if (c == '"') {
			j = dquote_end(s, i + 1, end, 0);
			ic_highlight(henv, i, j - i, "fd-string");
			hl_inner(henv, s, i + 1, j);
			if (!closed_by(s, i + 1, j, '"'))
				ic_highlight(henv, i, 1, "fd-error");
			i = j;
		} else if (c == '$' && i + 1 < end && s[i + 1] == '(') {
			j = paren_end(s, i + 2, end, 0);
			if (closed_by(s, i + 2, j, ')')) {
				ic_highlight(henv, i, 2, "fd-op");
				ic_highlight(henv, j - 1, 1, "fd-op");
				hl_range(henv, s, i + 2, j - 1);
			} else {
				hl_range(henv, s, i + 2, j);
				ic_highlight(henv, i, 2, "fd-error");
			}
			i = j;
		} else if (c == '$' && i + 1 < end && s[i + 1] == '{') {
			for (j = i + 2; j < end && s[j] != '}'; j++)
				;
			ic_highlight(henv, i, (j < end ? j + 1 : end) - i, j < end ? "fd-var" : "fd-error");
			j = j < end ? j + 1 : end;
			i = j;
		} else if (c == '$') {
			j = i + 1;
			if (j < end && strchr("?!$#*@-", s[j]))
				j++;
			else
				while (j < end && (isalnum((unsigned char)s[j]) || s[j] == '_'))
					j++;
			if (j > i + 1)
				ic_highlight(henv, i, j - i, "fd-var");
			i = j;
		} else {
			i++;
		}
	}
}

static void hl_word(ic_highlight_env_t *henv, const char *s, const struct token *t, const struct state *st)
{
	static struct sb text;
	const char *w = s + t->start;
	long n = t->end - t->start;
	int known = word_text(s, t->start, t->end, &text);

	if (st->redir) {
		if (known && access(text.s, F_OK) == 0)
			ic_highlight(henv, t->start, n, "fd-path");
	} else if (st->cmdpos && st->wrapper && *w == '-') {
		ic_highlight(henv, t->start, n, "fd-option");
	} else if (st->cmdpos && is_assignment(w, (size_t)n)) {
		long eq = (long)(strchr(w, '=') - w);

		ic_highlight(henv, t->start, eq, "fd-var");
		hl_inner(henv, s, t->start + eq + 1, t->end);
		return;
	} else if (st->cmdpos && is_keyword(w, (size_t)n)) {
		ic_highlight(henv, t->start, n, "fd-keyword");
		return;
	} else if (st->cmdpos) {
		if (known)
			ic_highlight(henv, t->start, n,
				     is_runnable(text.s) || is_dir(text.s) ? "fd-command" : "fd-error");
	} else if (*w == '-') {
		ic_highlight(henv, t->start, n, "fd-option");
	} else if (known && text.len && access(text.s, F_OK) == 0) {
		ic_highlight(henv, t->start, n, "fd-path");
	}
	hl_inner(henv, s, t->start, t->end);
}

/* What closes a construct a word opens, or 0. */
static char opener(const char *w, size_t n)
{
	static const char *const open[] = { "if", "case", "do", "{" };
	static const char close[] = { 'f', 'e', 'd', '}' };
	size_t k;

	for (k = 0; k < 4; k++)
		if (strlen(open[k]) == n && !strncmp(open[k], w, n))
			return close[k];
	return 0;
}

static char closer(const char *w, size_t n)
{
	static const char *const shut[] = { "fi", "esac", "done", "}" };
	static const char close[] = { 'f', 'e', 'd', '}' };
	size_t k;

	for (k = 0; k < 4; k++)
		if (strlen(shut[k]) == n && !strncmp(shut[k], w, n))
			return close[k];
	return 0;
}

/*
 * A closer with nothing open to close (fi, done, esac, } or a parenthesis)
 * is an error. One left open is not: the line may go on.
 */
static void hl_range(ic_highlight_env_t *henv, const char *s, long i, long lim)
{
	static int depth;
	struct state st = { 1, 0, 0 };
	struct token t;
	char open[MAX_NESTING];
	int nopen = 0;

	if (depth >= MAX_NESTING)
		return;
	depth++;
	for (;;) {
		struct state before = st;

		i = next_token(s, i, lim, &t);
		if (t.type == T_END)
			break;
		if (t.type == T_COMMENT) {
			ic_highlight(henv, t.start, t.end - t.start, "fd-comment");
		} else if (t.type == T_SEP && s[t.start] == '(') {
			ic_highlight(henv, t.start, 1, "fd-op");
			if (nopen < MAX_NESTING)
				open[nopen++] = ')';
		} else if (t.type == T_SEP && s[t.start] == ')') {
			/* it closes a subshell, or in a case ends a pattern */
			int ok = nopen && (open[nopen - 1] == ')' || open[nopen - 1] == 'e');

			if (ok && open[nopen - 1] == ')')
				nopen--;
			ic_highlight(henv, t.start, 1, ok ? "fd-op" : "fd-error");
		} else if (t.type == T_SEP || t.type == T_REDIR) {
			ic_highlight(henv, t.start, t.end - t.start, "fd-op");
		} else {
			size_t n = (size_t)(t.end - t.start);
			char c;

			hl_word(henv, s, &t, &st);
			if (before.cmdpos && !before.redir) {
				if ((c = opener(s + t.start, n)) && nopen < MAX_NESTING) {
					open[nopen++] = c;
				} else if ((c = closer(s + t.start, n))) {
					if (nopen && open[nopen - 1] == c)
						nopen--;
					else
						ic_highlight(henv, t.start, (long)n, "fd-error");
				}
			}
		}
		state_step(&st, s, &t);
	}
	depth--;
}

static void highlighter(ic_highlight_env_t *henv, const char *input, void *arg)
{
	(void)arg;
	hl_range(henv, input, 0, (long)strlen(input));
}

/* ------------------------------------------------------------- completion */

struct cand_ctx {
	ic_completion_env_t *cenv;
	const char *word;
	size_t len;
	const char *help;
};

static void cand_add(const char *name, void *arg)
{
	struct cand_ctx *c = arg;

	if (!strncmp(name, c->word, c->len))
		ic_add_completion_prim(c->cenv, name, NULL, c->help, (long)c->len, 0);
}

static void complete_commands(ic_completion_env_t *cenv, const char *word, size_t len)
{
	struct sb w = {0};
	struct cand_ctx c;
	size_t i;

	sb_add(&w, word, len);
	c.cenv = cenv;
	c.word = w.s;
	c.len = len;
	cmds_load();
	for (i = cmds_lower(w.s); i < ncmds && !strncmp(cmds[i], w.s, len); i++)
		if (!ic_add_completion_prim(cenv, cmds[i], NULL, NULL, (long)len, 0))
			break;
	if (!ic_stop_completing(cenv)) {
		c.help = "builtin";
		for (i = 0; i < NUMBUILTINS; i++)
			cand_add(builtincmd[i].name, &c);
		c.help = "alias";
		fdash_listaliases(cand_add, &c);
		c.help = "function";
		fdash_listfunctions(cand_add, &c);
		fdash_listautoload(cand_add, &c);
		c.help = "keyword";
		for (i = 0; i < sizeof(keywords) / sizeof(keywords[0]); i++)
			cand_add(keywords[i], &c);
	}
	free(w.s);
}

static void complete_variables(ic_completion_env_t *cenv, const char *name, size_t len)
{
	static struct sb var;
	struct stackmark mark;
	char **vars, **v;

	setstackmark(&mark);
	vars = listvars(0, VUNSET, NULL);
	for (v = vars; *v; v++) {
		const char *eq = strchr(*v, '=');

		if (!eq || (size_t)(eq - *v) < len || strncmp(*v, name, len))
			continue;
		sb_clear(&var);
		sb_add(&var, *v, (size_t)(eq - *v));
		ic_add_completion_prim(cenv, var.s, NULL, NULL, (long)len, 0);
	}
	popstackmark(&mark);
}

/* A backslash before anything the shell would treat specially. */
static void sb_escape(struct sb *b, const char *s, size_t n)
{
	size_t i;

	for (i = 0; i < n; i++) {
		if (s[i] && strchr(" \t\n'\"\\$`&|;()<>*?[]#~!{}=", s[i]))
			sb_chr(b, '\\');
		sb_chr(b, s[i]);
	}
}

/*
 * Files for the word [word, word + len), which may hold escapes or an opening
 * quote. Only the part after the last slash gets replaced. A tab press also
 * matches case-insensitively when nothing matches exactly; a suggestion must
 * not, because it can only append text.
 */
static void complete_files(ic_completion_env_t *cenv, const char *word, size_t len, int dirs_only)
{
	struct sb text = {0}, dir = {0}, full = {0}, rep = {0}, disp = {0};
	char quote = 0;
	const char *base, *slash;
	size_t base_raw = 0, i, base_len;
	int fold, added = 0;
	DIR *d;

	/* unquote, and find where the last path component starts in the raw word */
	if (word[0] == '~' && (len == 1 || word[1] == '/') && lookupvar("HOME")) {
		sb_str(&text, lookupvar("HOME"));
		i = 1;
	} else {
		sb_add(&text, "", 0);
		i = 0;
	}
	for (; i < len; i++) {
		char c = word[i];

		if (quote) {
			if (c == quote)
				quote = 0;
			else
				sb_chr(&text, c);
		} else if (c == '\'' || c == '"') {
			quote = c;
		} else if (c == '\\' && i + 1 < len) {
			sb_chr(&text, word[++i]);
		} else {
			sb_chr(&text, c);
		}
		if (word[i] == '/')
			base_raw = i + 1;
	}
	if (quote && base_raw == 0)
		base_raw = 1;	/* keep the opening quote */
	slash = strrchr(text.s, '/');
	base = slash ? slash + 1 : text.s;
	base_len = strlen(base);
	if (slash)
		sb_add(&dir, text.s, (size_t)(slash - text.s) + 1);
	else
		sb_str(&dir, "./");

	for (fold = 0; fold < 2 && !added; fold++) {
		struct dirent *e;

		if (fold && ic_completion_is_hint())
			break;
		if (!(d = opendir(dir.s)))
			break;
		while ((e = readdir(d))) {
			const char *n = e->d_name;
			const char *p;
			int isdir;

			if (!strcmp(n, ".") || !strcmp(n, ".."))
				continue;
			if (n[0] == '.' && base[0] != '.')
				continue;
			if (fold ? strncasecmp(n, base, base_len) : strncmp(n, base, base_len))
				continue;
			sb_clear(&full);
			sb_str(&full, dir.s);
			sb_str(&full, n);
			isdir = is_dir(full.s);
			if (dirs_only && !isdir)
				continue;
			sb_clear(&rep);
			if (!quote)
				sb_escape(&rep, n, strlen(n));
			for (p = n; quote && *p; p++) {
				if (*p == quote || (quote == '"' && strchr("$`\\", *p)))
					sb_chr(&rep, '\\');
				sb_chr(&rep, *p);
			}
			if (isdir)
				sb_chr(&rep, '/');
			sb_clear(&disp);
			if (isdir)
				sb_str(&disp, "[ansi-blue]");
			sb_markup(&disp, n);
			if (isdir)
				sb_str(&disp, "/[/]");
			added = 1;
			if (!ic_add_completion_prim(cenv, rep.s, disp.s, NULL, (long)(len - base_raw), 0))
				break;
		}
		closedir(d);
	}
	free(text.s);
	free(dir.s);
	free(full.s);
	free(rep.s);
	free(disp.s);
}

/* The completion spec for one command, kept until another command is completed. */
static char spec_name[64];
static char *spec_text;

/*
 * Hand-written specs win over ones generated from man pages; the user's own
 * win over the shipped ones.
 */
static const char *spec_load(const char *cmd)
{
	static struct sb path;
	int k;

	if (strchr(cmd, '/') || *cmd == '.' || strlen(cmd) >= sizeof(spec_name))
		return NULL;
	if (!strcmp(spec_name, cmd))
		return spec_text;
	strcpy(spec_name, cmd);
	free(spec_text);
	spec_text = NULL;
	for (k = 0; k < 4 && !spec_text; k++) {
		if (k == 0 && !config_dir(&path))
			continue;
		if (k == 2 && !data_dir(&path))
			continue;
		if (k == 1 || k == 3) {
			sb_clear(&path);
			sb_str(&path, FDASH_DATADIR);
		}
		sb_str(&path, k < 2 ? "/completions/" : "/generated_completions/");
		sb_str(&path, cmd);
		spec_text = read_text(path.s, 1 << 20);
	}
	return spec_text;
}

/*
 * A command without a spec gets one from its man page on the first tab after a
 * dash, by fdash-update-completions (a few milliseconds); once per session.
 */
static int spec_from_man(const char *cmd)
{
	static struct sb tried;
	struct sb out = {0}, prog = {0};
	const char *path = pathval(), *p;
	char *argv[3];
	int ok = 0;

	for (p = tried.s; p && p < tried.s + tried.len; p += strlen(p) + 1)
		if (!strcmp(p, cmd))
			return 0;
	sb_add(&tried, cmd, strlen(cmd) + 1);
	for (p = path; ; p++) {
		const char *end = strchr(p, ':');
		size_t n = end ? (size_t)(end - p) : strlen(p);

		sb_clear(&prog);
		sb_add(&prog, p, n);
		sb_str(&prog, "/fdash-update-completions");
		if (n && *prog.s == '/' && access(prog.s, X_OK) == 0) {
			struct stackmark mark;

			argv[0] = prog.s;
			argv[1] = (char *)cmd;
			argv[2] = NULL;
			setstackmark(&mark);
			ok = run_capture(argv, listvars(VEXPORT, VUNSET, NULL), 3000, &out, 4096) == 0;
			popstackmark(&mark);
			break;
		}
		if (!end)
			break;
		p = end;
	}
	free(out.s);
	free(prog.s);
	spec_name[0] = 0;	/* read the spec again */
	return ok;
}

/* The words typed after the command, apart from options, and the options. */
#define MAX_TYPED 64

struct typed {
	const char *words[MAX_TYPED];
	const char *opts[MAX_TYPED];
	int nwords, nopts;
};

/* Was the option typed? "-R" also matches inside a cluster such as -Rs. */
static int opt_typed(const struct typed *ty, const char *o, size_t n)
{
	int i;

	for (i = 0; i < ty->nopts; i++) {
		const char *t = ty->opts[i];

		if (n == 2 && o[1] != '-' && t[1] != '-' && strchr(t + 1, o[1]))
			return 1;
		if (!strncmp(t, o, n) && (t[n] == 0 || t[n] == '='))
			return 1;
	}
	return 0;
}

/* "-R|--repository" holds when one of them was typed, "!-R|--repository" when none was. */
static int cond_holds(const char *p, size_t n, const struct typed *ty)
{
	int neg = *p == '!', found = 0;
	const char *end = p + n;

	for (p += neg; p < end && !found; ) {
		size_t k = 0;

		while (p + k < end && p[k] != '|')
			k++;
		found = k > 1 && opt_typed(ty, p, k);
		p += k + 1;
	}
	return found != neg;
}

static int alt_has(const char *p, size_t n, const char *word)
{
	const char *end = p + n;
	size_t wl = strlen(word);

	while (p < end) {
		size_t k = 0;

		while (p + k < end && p[k] != '|')
			k++;
		if (k == wl && !strncmp(p, word, k))
			return 1;
		p += k + 1;
	}
	return 0;
}

/*
 * The pattern before a spec line's item: subcommands ("a|b" for either), "*"
 * for any one word, a final "..." for any further words, and option
 * conditions that take no word. Options are offered after further words too.
 */
static int spec_matches(const char *p, size_t plen, int is_option, const struct typed *ty)
{
	const char *end = p + plen;
	int i = 0, rest = is_option;

	while (p < end) {
		size_t n = 0;

		while (p < end && *p == ' ')
			p++;
		while (p + n < end && p[n] != ' ')
			n++;
		if (!n)
			break;
		if (*p == '-' || *p == '!') {
			if (!cond_holds(p, n, ty))
				return 0;
		} else if (n == 3 && !strncmp(p, "...", 3)) {
			rest = 1;
		} else {
			if (i >= ty->nwords || !((n == 1 && *p == '*') || alt_has(p, n, ty->words[i])))
				return 0;
			i++;
		}
		p += n;
	}
	return rest ? i <= ty->nwords : i == ty->nwords;
}

struct spec_ctx {
	ic_completion_env_t *cenv;
	const char *raw;	/* the word being completed, as typed */
	size_t rawlen;
	const char *text;	/* and as the shell reads it */
	size_t len;
	const char *help;	/* the spec line's description */
	int found;
};

static int spec_cand(const char *w, size_t n, const char *help, void *arg)
{
	static struct sb rep, disp, desc, tmp;
	struct spec_ctx *c = arg;
	size_t i;

	if (n < c->len || strncmp(w, c->text, c->len))
		return 1;
	for (i = 0; i < n; i++)
		if (control_len(w + i))
			return 1;
	sb_clear(&rep);
	sb_escape(&rep, w, n);
	sb_clear(&tmp);
	sb_add(&tmp, w, n);
	sb_clear(&disp);
	sb_markup(&disp, tmp.s);
	sb_clear(&desc);
	if (help || c->help)
		sb_markup(&desc, help ? help : c->help);
	c->found = 1;
	return ic_add_completion_prim(c->cenv, rep.s, disp.s, desc.len ? desc.s : NULL, (long)c->rawlen, 0);
}

static void complete_commands(ic_completion_env_t *cenv, const char *word, size_t len);
static void complete_files(ic_completion_env_t *cenv, const char *word, size_t len, int dirs_only);

/* Items from a generator: @files, @dirs and @commands, or a list from gen.c. */
static void spec_generate(struct spec_ctx *c, const char *name)
{
	ic_completion_env_t *cenv = c->cenv;

	if (!strcmp(name, "files") || !strcmp(name, "dirs")) {
		complete_files(cenv, c->raw, c->rawlen, name[0] == 'd');
		c->found |= ic_has_completions(cenv);
	} else if (!strcmp(name, "commands")) {
		if (c->rawlen || !ic_completion_is_hint())
			complete_commands(cenv, c->raw, c->rawlen);
		c->found |= ic_has_completions(cenv);
	} else {
		gen_run(name, ic_completion_is_hint(), spec_cand, c);
	}
}

/*
 * Spec lines are "[pattern ...] item<TAB>description". The item is a word to
 * offer, or @name for the words a generator gives.
 */
static int complete_spec(struct spec_ctx *c, const char *spec, const struct typed *ty)
{
	static struct sb item, help;

	/* a suggestion only appends: it cannot line up with a quoted word */
	if (ic_completion_is_hint() && (c->rawlen != c->len || strncmp(c->raw, c->text, c->len)))
		return 0;
	while (*spec && !ic_stop_completing(c->cenv)) {
		const char *eol = strchr(spec, '\n');
		const char *tab, *last, *p;
		size_t n = eol ? (size_t)(eol - spec) : strlen(spec);

		tab = memchr(spec, '\t', n);
		p = tab ? tab : spec + n;
		while (p > spec && p[-1] == ' ')
			p--;
		for (last = p; last > spec && last[-1] != ' '; last--)
			;
		/* options only when the word starts with a dash, as in fish */
		if (n && spec[0] != '#' && p > last && (*last == '-') == (c->text[0] == '-')
		    && spec_matches(spec, (size_t)(last - spec), *last == '-', ty)) {
			sb_clear(&help);
			if (tab)
				sb_add(&help, tab + 1, (size_t)(spec + n - tab - 1));
			c->help = tab && help.len ? help.s : NULL;
			sb_clear(&item);
			sb_add(&item, last, (size_t)(p - last));
			if (*last == '@' && p - last > 1)
				spec_generate(c, item.s + 1);
			else
				spec_cand(item.s, item.len, NULL, c);
		}
		spec += n + (eol ? 1 : 0);
	}
	return c->found;
}

static void completer(ic_completion_env_t *cenv, const char *input)
{
	static struct sb cmd, text, words, cur;
	static struct typed ty;
	size_t offs[2 * MAX_TYPED];
	struct state st = { 1, 0, 0 };
	struct token t;
	long lim = (long)strlen(input), i = 0, wstart = lim;
	const char *word, *dollar;
	size_t len;
	int nw = 0, no = 0, k, dashdash = 0;
	char kinds[2 * MAX_TYPED];

	sb_clear(&cmd);
	sb_clear(&words);
	for (;;) {
		struct state before = st;

		i = next_token(input, i, lim, &t);
		if (t.type == T_END)
			break;
		if (t.type == T_COMMENT)
			return;
		if (t.type == T_WORD && t.end == lim) {
			wstart = t.start;
			break;
		}
		state_step(&st, input, &t);
		if (t.type == T_SEP) {
			sb_clear(&cmd);
			sb_clear(&words);
			nw = no = dashdash = 0;
		} else if (t.type == T_WORD && !before.redir) {
			size_t n = (size_t)(t.end - t.start);
			int known;

			if (before.cmdpos && !before.wrapper && is_assignment(input + t.start, n))
				continue;
			known = word_text(input, t.start, t.end, &text);
			if (before.cmdpos) {
				if (known) {
					sb_clear(&cmd);
					sb_str(&cmd, text.s);
				}
				sb_clear(&words);
				nw = no = dashdash = 0;
			} else if (nw + no < 2 * MAX_TYPED - 1 && (nw < MAX_TYPED && no < MAX_TYPED)) {
				int opt = !dashdash && input[t.start] == '-' && n > 1;

				if (n == 2 && !strncmp(input + t.start, "--", 2))
					dashdash = 1;
				offs[nw + no] = words.len;
				kinds[nw + no] = (char)opt;
				if (known)
					sb_str(&words, text.s);
				else
					sb_add(&words, input + t.start, n);
				sb_chr(&words, 0);
				if (opt)
					no++;
				else
					nw++;
			}
		}
	}
	ty.nwords = ty.nopts = 0;
	for (k = 0; k < nw + no; k++) {
		if (kinds[k])
			ty.opts[ty.nopts++] = words.s + offs[k];
		else
			ty.words[ty.nwords++] = words.s + offs[k];
	}
	word = input + wstart;
	len = (size_t)(lim - wstart);

	if ((dollar = strrchr(word, '$'))) {
		const char *p = dollar + 1;

		if (*p == '{')
			p++;
		if (!*p || strspn(p, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_") == strlen(p)) {
			if (!ic_completion_is_hint() || *p)
				complete_variables(cenv, p, strlen(p));
			return;
		}
	}
	if (st.redir) {
		complete_files(cenv, word, len, 0);
		return;
	}
	if (st.cmdpos && !memchr(word, '/', len) && word[0] != '~' && word[0] != '.') {
		if (len || !ic_completion_is_hint())
			complete_commands(cenv, word, len);
		if (!ic_has_completions(cenv) && (len || !ic_completion_is_hint()))
			complete_files(cenv, word, len, 1);
		return;
	}
	if (!st.cmdpos && cmd.len) {
		const char *spec = spec_load(cmd.s);

		if (!spec && word[0] == '-' && !ic_completion_is_hint() && spec_from_man(cmd.s))
			spec = spec_load(cmd.s);

		if (spec && word_text(input, wstart, lim, &cur)) {
			struct spec_ctx c = { cenv, word, len, cur.s, cur.len, NULL, 0 };

			if (complete_spec(&c, spec, &ty))
				return;
		}
		if (word[0] == '-')
			return;
	}
	complete_files(cenv, word, len, !st.cmdpos && (!strcmp(cmd.s ? cmd.s : "", "cd") || !strcmp(cmd.s ? cmd.s : "", "pushd")));
}

/* ---------------------------------------------------------- abbreviations */

struct abbr {
	char *name, *value;
	struct abbr *next;
};

static struct abbr *abbrs;

/* Replaces the word that ends at the cursor when a command is expected there. */
static const char *abbr_expand(const char *input, long pos, long *start, void *arg)
{
	struct state st = { 1, 0, 0 };
	struct token t;
	long i = 0;

	(void)arg;
	if (!abbrs)
		return NULL;
	for (;;) {
		i = next_token(input, i, pos, &t);
		if (t.type == T_END || t.type == T_COMMENT)
			return NULL;
		if (t.type == T_WORD && t.end == pos) {
			struct abbr *a;
			size_t n = (size_t)(t.end - t.start);

			if (!st.cmdpos || st.redir)
				return NULL;
			for (a = abbrs; a; a = a->next) {
				if (strlen(a->name) == n && !strncmp(a->name, input + t.start, n)) {
					*start = t.start;
					return a->value;
				}
			}
			return NULL;
		}
		state_step(&st, input, &t);
	}
}

static void abbr_remove(const char *name)
{
	struct abbr **ap;

	for (ap = &abbrs; *ap; ap = &(*ap)->next) {
		if (!strcmp((*ap)->name, name)) {
			struct abbr *a = *ap;

			*ap = a->next;
			free(a->name);
			free(a->value);
			free(a);
			return;
		}
	}
}

int abbrcmd(int argc, char **argv)
{
	struct sb value = {0};
	struct abbr *a;
	int i = 1;

	if (argc < 2) {
		for (a = abbrs; a; a = a->next)
			out1fmt("abbr %s %s\n", a->name, single_quote(a->value));
		return 0;
	}
	if (!strcmp(argv[1], "-e") || !strcmp(argv[1], "--erase")) {
		for (i = 2; i < argc; i++)
			abbr_remove(argv[i]);
		return 0;
	}
	if (!strcmp(argv[1], "-a") || !strcmp(argv[1], "--add"))
		i = 2;
	if (argc - i < 2)
		sh_error("usage: abbr [-a] name expansion... | abbr -e name...");
	for (int j = i + 1; j < argc; j++) {
		if (j > i + 1)
			sb_chr(&value, ' ');
		sb_str(&value, argv[j]);
	}
	abbr_remove(argv[i]);
	a = malloc(sizeof(*a));
	if (a) {
		a->name = strdup(argv[i]);
		a->value = value.s;
		a->next = abbrs;
		abbrs = a;
	}
	return 0;
}

/* ---------------------------------------------------------------- prompt */

static int setup_done;
static time_t command_started;

static const char *current_dir(void)
{
	static char buf[PATH_MAX];
	const char *pwd = lookupvar("PWD");

	if (pwd && *pwd == '/')
		return pwd;
	return getcwd(buf, sizeof(buf));
}

/* Each directory but the last cut to its first character, as in fish: ~/D/s/void */
static void add_short_path(struct sb *out, const char *cwd)
{
	const char *home = lookupvar("HOME");
	struct sb path = {0};
	const char *p, *slash;

	if (home && *home && !strncmp(cwd, home, strlen(home))
	    && (cwd[strlen(home)] == 0 || cwd[strlen(home)] == '/')) {
		sb_chr(&path, '~');
		sb_str(&path, cwd + strlen(home));
	} else {
		sb_str(&path, cwd);
	}
	for (p = path.s; (slash = strchr(p, '/')); p = slash + 1) {
		const char *q = p;

		if (slash > p) {
			if (*q == '.' && q + 1 < slash)
				q++;
			q++;
			while (q < slash && ((unsigned char)*q & 0xC0) == 0x80)
				q++;
			{
				struct sb part = {0};

				sb_add(&part, p, (size_t)(q - p));
				sb_markup(out, part.s);
				free(part.s);
			}
		}
		sb_chr(out, '/');
	}
	sb_markup(out, p);
	free(path.s);
}

/* The current git branch, read from .git/HEAD: no fork, so it costs nothing per prompt. */
static int git_branch(const char *cwd, char *out, size_t size)
{
	struct sb path = {0}, dir = {0};
	char line[PATH_MAX];
	int found = 0;

	sb_str(&dir, cwd);
	for (;;) {
		struct stat st;
		char *slash;

		sb_clear(&path);
		sb_str(&path, dir.s);
		sb_str(&path, "/.git");
		if (stat(path.s, &st) == 0) {
			/* in a worktree or submodule .git is a file naming the real directory */
			if (read_first_line(path.s, line, sizeof(line)) && !strncmp(line, "gitdir: ", 8)) {
				sb_clear(&path);
				if (line[8] != '/') {
					sb_str(&path, dir.s);
					sb_chr(&path, '/');
				}
				sb_str(&path, line + 8);
			}
			sb_str(&path, "/HEAD");
			if (read_first_line(path.s, line, sizeof(line))) {
				size_t hex = strspn(line, "0123456789abcdef");

				if (!strncmp(line, "ref: refs/heads/", 16)) {
					snprintf(out, size, "%s", line + 16);
					found = 1;
				} else if (!line[hex] && (hex == 40 || hex == 64)) {
					snprintf(out, size, "%.8s", line);
					found = 1;
				}
			}
			break;
		}
		slash = strrchr(dir.s, '/');
		if (!slash || slash == dir.s)
			break;
		*slash = 0;
		dir.len = (size_t)(slash - dir.s);
	}
	free(path.s);
	free(dir.s);
	return found;
}

static const char *fish_prompt(void)
{
	static struct sb p;
	static char user[64], host[64];
	const char *cwd = current_dir();
	char branch[128];
	char num[32];

	if (!user[0]) {
		struct passwd *pw = getpwuid(geteuid());

		const char *name = pw ? pw->pw_name : lookupvar("USER");

		snprintf(user, sizeof(user), "%s", name ? name : "?");
		if (gethostname(host, sizeof(host) - 1))
			snprintf(host, sizeof(host), "?");
	}
	sb_clear(&p);
	if (exitstatus) {
		snprintf(num, sizeof(num), "[ansi-red]\\[%d][/] ", exitstatus);
		sb_str(&p, num);
	}
	sb_str(&p, geteuid() ? "[ansi-green]" : "[ansi-red]");
	sb_markup(&p, user);
	sb_chr(&p, '@');
	sb_markup(&p, host);
	sb_str(&p, "[/] [ansi-cyan]");
	if (cwd) {
		add_short_path(&p, cwd);
		sb_str(&p, "[/]");
		if (git_branch(cwd, branch, sizeof(branch))) {
			sb_str(&p, " [ansi-magenta](");
			sb_markup(&p, branch);
			sb_str(&p, ")[/]");
		}
	} else {
		sb_str(&p, "?[/]");
	}
	if (command_started) {
		long took = (long)(time(NULL) - command_started);

		if (took >= SLOW_COMMAND_SECONDS) {
			snprintf(num, sizeof(num), " [ansi-yellow]%lds[/]", took);
			sb_str(&p, num);
		}
		command_started = 0;
	}
	sb_str(&p, geteuid() ? "> " : "# ");
	return p.s;
}

/* PS1 and PS2 are plain text: color escapes are dropped, brackets stay brackets. */
static const char *plain_prompt(const char *text)
{
	static struct sb p;
	const char *s;

	sb_clear(&p);
	for (s = text; *s; s++) {
		if (*s == '\033') {
			if (s[1] == '[') {
				for (s += 2; *s && !(*s >= '@' && *s <= '~'); s++)
					;
			}
			if (!*s)
				break;
			continue;
		}
		if (*s == '[' || *s == '\\')
			sb_chr(&p, '\\');
		sb_chr(&p, *s);
	}
	return p.s;
}

/* FDASH_PS1 takes isocline markup, an untouched PS1 gets the fish prompt. */
static const char *make_prompt(void)
{
	const char *custom = lookupvar("FDASH_PS1");
	const char *ps1;

	if (whichprompt == 2)
		return plain_prompt(getprompt(NULL));
	if (whichprompt != 1)
		return "";
	if (custom && *custom)
		return expandstr(custom);
	ps1 = ps1val();
	if (!strcmp(ps1, "$ ") || !strcmp(ps1, "# "))
		return fish_prompt();
	return plain_prompt(getprompt(NULL));
}

/* Shell integration for terminals like foot: prompt marks, the working directory, a title. */
static void announce_prompt(void)
{
	static struct sb seq;
	static char host[64];
	const char *term = lookupvar("TERM");
	const char *cwd = current_dir();
	const char *p;

	if (!term || !strcmp(term, "dumb") || !strcmp(term, "linux") || !cwd)
		return;
	if (!host[0] && gethostname(host, sizeof(host) - 1))
		host[0] = 0;
	sb_clear(&seq);
	sb_str(&seq, "\033]133;A\033\\\033]7;file://");
	sb_str(&seq, host);
	for (p = cwd; *p; p++) {
		if ((unsigned char)*p > 0x20 && (unsigned char)*p < 0x7f && *p != '%') {
			sb_chr(&seq, *p);
		} else {
			char hex[8];

			snprintf(hex, sizeof(hex), "%%%02X", (unsigned char)*p);
			sb_str(&seq, hex);
		}
	}
	sb_str(&seq, "\033\\\033]0;");
	for (p = cwd; *p; ) {
		int ctl = control_len(p);

		if (ctl)
			p += ctl;
		else
			sb_chr(&seq, *p++);
	}
	sb_str(&seq, "\007");
	if (write(2, seq.s, seq.len) < 0)
		return;
}

/* ------------------------------------------------------------------- keys */

/*
 * Keys as in fish. Those that need the shell (prevd, man, ls, the editor)
 * hand it a command: the input leaves the screen, the command runs as if
 * typed, but stays out of the history and keeps $?, and the input comes back
 * at the next prompt. bind adds keys of the same kind; commandline reads and
 * changes the input from their commands.
 */
struct binding {
	char *key, *command;
	struct binding *next;
};

static struct binding *bindings;
static struct sb kept_input;	/* the input while a key's command runs */
static long kept_pos = -1;
static int key_pending;		/* the line being run came from a key */
static int key_status;		/* $? before it */
static char *edit_file;		/* Alt+E: the file the editor works on */

/* The simple command the cursor is in: its name, its first argument, and the word at the cursor. */
static void line_at(const char *input, long pos, struct sb *cmd, struct sb *arg, struct sb *word)
{
	struct state st = { 1, 0, 0 };
	struct token t;
	long lim = (long)strlen(input), i = 0;

	sb_clear(cmd);
	sb_clear(arg);
	sb_clear(word);
	for (;;) {
		struct state before = st;

		i = next_token(input, i, lim, &t);
		if (t.type == T_END || t.type == T_COMMENT || t.start > pos)
			break;
		state_step(&st, input, &t);
		if (t.type == T_SEP) {
			if (t.end <= pos) {
				sb_clear(cmd);
				sb_clear(arg);
			}
			continue;
		}
		if (t.type != T_WORD || before.redir)
			continue;
		if (pos <= t.end && !word_text(input, t.start, t.end, word))
			sb_clear(word);
		if (before.cmdpos && !(before.wrapper && input[t.start] == '-')) {
			if (!is_assignment(input + t.start, (size_t)(t.end - t.start)) && word_text(input, t.start, t.end, cmd))
				sb_clear(arg);
		} else if (cmd->len && !arg->len && input[t.start] != '-' && t.end < pos) {
			word_text(input, t.start, t.end, arg);
		}
	}
}

static ic_key_action_t run_for_key(const char *input, long pos, const char *command, const char **text)
{
	sb_clear(&kept_input);
	sb_str(&kept_input, input);
	kept_pos = pos;
	key_pending = 1;
	*text = command;
	return IC_KEY_RUN;
}

static ic_key_action_t key_handler(const char *name, const char *input, long pos,
				   const char **text, long *newpos, void *arg)
{
	static struct sb out, cmd, sub, word;
	struct binding *b;
	const char *p;

	(void)arg;
	sb_clear(&out);
	for (b = bindings; b; b = b->next)
		if (!strcmp(b->key, name))
			return whichprompt == 1 ? run_for_key(input, pos, b->command, text) : IC_KEY_IGNORE;
	if (!strcmp(name, "alt-s")) {
		/* doas in front, or off again; on an empty line, before the last command */
		const char *pre = is_runnable("doas") || !is_runnable("sudo") ? "doas " : "sudo ";
		const char *prev = ic_history_get(1);

		if (!strncmp(input, pre, 5)) {
			sb_str(&out, input + 5);
			*newpos = pos > 5 ? pos - 5 : 0;
		} else {
			sb_str(&out, pre);
			sb_str(&out, *input || !prev ? input : prev);
			*newpos = *input ? pos + 5 : -1;
		}
		*text = out.s;
		return IC_KEY_EDITED;
	}
	if (whichprompt != 1)
		return IC_KEY_IGNORE;
	for (p = input; *p == ' ' || *p == '\t'; p++)
		;
	if (!strcmp(name, "alt-left") || !strcmp(name, "alt-right")) {
		if (*p)
			return IC_KEY_IGNORE;	/* the editor moves by words */
		return run_for_key(input, pos, name[4] == 'l' ? "prevd 2>/dev/null" : "nextd 2>/dev/null", text);
	}
	if (!strcmp(name, "alt-e") || !strcmp(name, "alt-v")) {
		const char *tmp = lookupvar("TMPDIR");
		int fd;

		sb_str(&out, tmp && *tmp == '/' ? tmp : "/tmp");
		sb_str(&out, "/fdash-line.XXXXXX.sh");
		if ((fd = mkstemps(out.s, 3)) < 0)
			return IC_KEY_IGNORE;
		if (write(fd, input, strlen(input)) < 0 || write(fd, "\n", 1) < 0) {
			close(fd);
			unlink(out.s);
			return IC_KEY_IGNORE;
		}
		close(fd);
		free(edit_file);
		edit_file = strdup(out.s);
		sb_clear(&cmd);
		sb_str(&cmd, "${VISUAL:-${EDITOR:-vi}} ");
		sb_quote(&cmd, out.s);
		return run_for_key(input, pos, cmd.s, text);
	}
	line_at(input, pos, &cmd, &sub, &word);
	if (!strcmp(name, "alt-h") || !strcmp(name, "f1")) {
		/* git commit: git-commit(1) if there is one */
		if (!cmd.len)
			return IC_KEY_IGNORE;
		sb_str(&out, "man -- ");
		if (sub.len) {
			sb_clear(&word);
			sb_str(&word, cmd.s);
			sb_chr(&word, '-');
			sb_str(&word, sub.s);
			sb_quote(&out, word.s);
			sb_str(&out, " 2>/dev/null || man -- ");
		}
		sb_quote(&out, cmd.s);
		return run_for_key(input, pos, out.s, text);
	}
	if (!strcmp(name, "alt-l")) {
		sb_str(&out, "ls");
		if (word.len && is_dir(word.s)) {
			sb_str(&out, " -- ");
			sb_quote(&out, word.s);
		}
		return run_for_key(input, pos, out.s, text);
	}
	if (!strcmp(name, "alt-w")) {
		if (!cmd.len)
			return IC_KEY_IGNORE;
		sb_str(&out, "whatis -- ");
		sb_quote(&out, cmd.s);
		sb_str(&out, " 2>/dev/null || type ");
		sb_quote(&out, cmd.s);
		return run_for_key(input, pos, out.s, text);
	}
	return IC_KEY_IGNORE;
}

/* At the prompt after a key's command: its input comes back, and $? is what it was. */
static void key_done(void)
{
	char *text;

	if (!key_pending)
		return;
	key_pending = 0;
	exitstatus = key_status;
	if (edit_file) {
		if ((text = read_text(edit_file, 1 << 20))) {
			size_t n = strlen(text);

			while (n && text[n - 1] == '\n')
				text[--n] = 0;
			sb_clear(&kept_input);
			sb_str(&kept_input, text);
			kept_pos = -1;
			free(text);
		}
		unlink(edit_file);
		free(edit_file);
		edit_file = NULL;
	}
	ic_set_initial_input(kept_input.s ? kept_input.s : "", kept_pos);
}

static int key_ok(const char *k)
{
	static const char *const arrows[] = { "alt-up", "alt-down", "alt-left", "alt-right" };
	size_t i;

	if (!strncmp(k, "alt-", 4) && k[4] > ' ' && k[4] < 0x7f && !k[5])
		return 1;
	for (i = 0; i < 4; i++)
		if (!strcmp(k, arrows[i]))
			return 1;
	return k[0] == 'f' && atoi(k + 1) >= 1 && atoi(k + 1) <= 12 && strspn(k + 1, "0123456789") == strlen(k + 1);
}

/* bind KEY COMMAND, bind -e KEY, bind: list. KEY is alt-x, alt-left and the like, or f1 to f12. */
int bindcmd(int argc, char **argv)
{
	struct binding **bp, *b;

	if (argc < 2) {
		for (b = bindings; b; b = b->next)
			out1fmt("bind %s %s\n", b->key, single_quote(b->command));
		return 0;
	}
	if (!strcmp(argv[1], "-e")) {
		if (argc < 3)
			sh_error("usage: bind -e key");
		for (bp = &bindings; *bp; bp = &(*bp)->next) {
			if (!strcmp((*bp)->key, argv[2])) {
				b = *bp;
				*bp = b->next;
				free(b->key);
				free(b->command);
				free(b);
				return 0;
			}
		}
		return 1;
	}
	if (argc != 3 || !key_ok(argv[1]))
		sh_error("usage: bind alt-x|alt-left|f1... command | bind -e key");
	for (b = bindings; b && strcmp(b->key, argv[1]); b = b->next)
		;
	if (!b) {
		if (!(b = calloc(1, sizeof(*b))))
			return 1;
		b->key = strdup(argv[1]);
		b->next = bindings;
		bindings = b;
	}
	free(b->command);
	b->command = strdup(argv[2]);
	return 0;
}

/*
 * In a key's command: commandline prints the input, commandline TEXT replaces
 * it, -i TEXT inserts at the cursor, -C prints or sets the cursor.
 */
int commandlinecmd(int argc, char **argv)
{
	struct sb text = {0};
	long len = kept_input.s ? (long)kept_input.len : 0;
	long pos = kept_pos < 0 || kept_pos > len ? len : kept_pos;

	if (argc < 2) {
		out1fmt("%s\n", kept_input.s ? kept_input.s : "");
		return 0;
	}
	if (!strcmp(argv[1], "-C")) {
		if (argc < 3) {
			out1fmt("%ld\n", pos);
			return 0;
		}
		kept_pos = number(argv[2]);
		return 0;
	}
	if (!strcmp(argv[1], "-i") && argc == 3) {
		sb_add(&text, kept_input.s ? kept_input.s : "", (size_t)pos);
		sb_str(&text, argv[2]);
		kept_pos = (long)text.len;
		sb_str(&text, kept_input.s ? kept_input.s + pos : "");
	} else if (argc == 2) {
		sb_str(&text, argv[1]);
		kept_pos = -1;
	} else {
		sh_error("usage: commandline [-i] [text] | commandline -C [position]");
	}
	sb_clear(&kept_input);
	sb_str(&kept_input, text.s);
	free(text.s);
	return 0;
}

/* -------------------------------------------------------------- reading */

static void setup(void)
{
	struct sb path = {0};
	const char *dir;

	setup_done = 1;
	ic_init(true);
	ic_set_prompt_marker("", "");
	ic_style_def("ic-prompt", "");
	ic_style_def("ic-hint", "ansi-darkgray");
	ic_style_def("fd-command", "ansi-blue");
	ic_style_def("fd-error", "ansi-red");
	ic_style_def("fd-keyword", "ansi-magenta");
	ic_style_def("fd-string", "ansi-yellow");
	ic_style_def("fd-var", "ansi-cyan");
	ic_style_def("fd-escape", "ansi-cyan");
	ic_style_def("fd-option", "ansi-teal");
	ic_style_def("fd-op", "ansi-cyan");
	ic_style_def("fd-comment", "ansi-darkgray");
	ic_style_def("fd-path", "underline");
	ic_set_default_highlighter(highlighter, NULL);
	ic_set_default_completer(completer, NULL);
	ic_set_abbr_expander(abbr_expand, NULL);
	ic_set_key_handler(key_handler, NULL);
	ic_enable_hint(true);
	ic_set_hint_delay(0);
	ic_enable_inline_help(false);
	ic_enable_brace_insertion(false);
	ic_enable_brace_matching(false);	/* it would not know quotes; the highlighter marks strays */
	ic_enable_beep(false);
	ic_set_multiline_eol(0);	/* a trailing backslash must stay a POSIX continuation */

	if ((dir = lookupvar("XDG_DATA_HOME")) && *dir) {
		sb_str(&path, dir);
	} else if ((dir = lookupvar("HOME")) && *dir) {
		sb_str(&path, dir);
		sb_str(&path, "/.local");
		mkdir(path.s, 0700);
		sb_str(&path, "/share");
	} else {
		free(path.s);
		return;
	}
	mkdir(path.s, 0700);
	sb_str(&path, "/fdash");
	mkdir(path.s, 0700);
	sb_str(&path, "/history");
	ic_set_history(path.s, HISTORY_MAX);
	free(path.s);
}

static int line_saved;

/* Is the line being run the newest history entry? fc leaves it out. */
int fdash_line_saved(void)
{
	return line_saved && setup_done;
}

int fdash_active(void)
{
	return iflag && isatty(0) && isatty(2);
}

/* A lone directory name means cd, a lone dash means cd back. Returns the line to run. */
static const char *implicit_cd(const char *line, struct sb *out)
{
	static struct sb text;
	const char *p;
	struct token t;
	long lim = (long)strlen(line), i;

	i = next_token(line, 0, lim, &t);
	if (t.type != T_WORD)
		return line;
	{
		struct token rest;

		next_token(line, i, lim, &rest);
		if (rest.type != T_END)
			return line;
	}
	for (p = line + t.start; p < line + t.end; p++)
		if (!((unsigned char)*p >= 0x80 || isalnum((unsigned char)*p) || strchr("_./~+-", *p)))
			return line;
	if (t.end - t.start == 1 && line[t.start] == '-') {
		sb_clear(out);
		sb_str(out, "cd -");
		return out->s;
	}
	if (is_keyword(line + t.start, (size_t)(t.end - t.start)) || !word_text(line, t.start, t.end, &text))
		return line;
	if (is_runnable(text.s) || !is_dir(text.s))
		return line;
	sb_clear(out);
	sb_str(out, "cd -- ");
	sb_add(out, line + t.start, (size_t)(t.end - t.start));
	return out->s;
}

int fdash_read(char *buf, int n)
{
	static struct sb pending;
	static size_t off;
	size_t left;

	if (off >= pending.len) {
		static struct sb rewritten;
		struct stackmark mark;
		const char *prompt, *line, *rprompt;
		char *res;

		if (!setup_done)
			setup();
		pushstackmark(&mark, stackblocksize());
		if (whichprompt == 1) {
			key_done();
			fdash_setstatus(exitstatus);
			cmds_check();
			fdash_dirh_update();
			fdash_uvars_check();
		}
		prompt = make_prompt();
		ic_set_vi_mode(Vflag);
		if (whichprompt == 1 && (rprompt = lookupvar("FDASH_RPROMPT")) && *rprompt)
			ic_set_right_prompt(expandstr(rprompt));
		else
			ic_set_right_prompt(NULL);
		flushall();
		if (whichprompt == 1)
			announce_prompt();
		/* no exception may unwind through the line editor */
		INTOFF;
		res = ic_readline(prompt);
		popstackmark(&mark);
		if (!res) {
			INTON;
			return 0;
		}
		/* isocline keeps lines of two characters or more that do not start with a space */
		line_saved = !key_pending && res[0] != ' ' && res[0] && res[1];
		if (key_pending) {
			/* a key's command: the prompt shows how the user's own command went */
			key_status = exitstatus;
			line = res;
			command_started = 0;
		} else {
			line = implicit_cd(res, &rewritten);
			command_started = time(NULL);
		}
		sb_clear(&pending);
		sb_str(&pending, line);
		sb_chr(&pending, '\n');
		off = 0;
		ic_free(res);
		INTON;
	}
	left = pending.len - off;
	if ((size_t)n > left)
		n = (int)left;
	memcpy(buf, pending.s + off, (size_t)n);
	off += (size_t)n;
	return n;
}

int historycmd(int argc, char **argv)
{
	long count, i, shown;

	if (!setup_done)
		setup();
	if (argc > 1 && !strcmp(argv[1], "clear")) {
		ic_history_clear();
		return 0;
	}
	if (argc > 1 && !strcmp(argv[1], "search")) {
		if (argc < 3)
			sh_error("usage: history search text");
		count = ic_history_count();
		for (i = count - 1; i >= 0; i--) {
			const char *e = ic_history_get(i);

			if (e && strstr(e, argv[2]))
				out1fmt("%s\n", e);
		}
		return 0;
	}
	count = ic_history_count();
	shown = argc > 1 ? number(argv[1]) : count;
	if (shown > count)
		shown = count;
	for (i = shown - 1; i >= 0; i--) {
		const char *e = ic_history_get(i);

		if (e)
			out1fmt("%s\n", e);
	}
	return 0;
}
