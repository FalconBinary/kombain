/*
 * fdash builtins beyond the line editor: directory history and universal
 * variables. They are POSIX-named commands, so scripts that never call them
 * see plain dash.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#include "shell.h"
#include "builtins.h"
#include "error.h"
#include "eval.h"
#include "memalloc.h"
#include "mystring.h"
#include "options.h"
#include "output.h"
#include "parser.h"
#include "var.h"

#include "fdash.h"
#include "util.h"

/* Before config.sh runs, in interactive shells on a terminal. */
void fdash_startup(void)
{
	if (fdash_active())
		fdash_uvars_check();
}

/* ------------------------------------------------------ directory history */

#define DIRH_MAX 25

/* Oldest first: the last entry of each is the next one prevd or nextd visits. */
static char *dirprev[DIRH_MAX], *dirnext[DIRH_MAX];
static int nprev, nnext;
static char *dirh_here;	/* the directory at the last prompt */

static const char *pwd_now(void)
{
	const char *pwd = lookupvar("PWD");

	return pwd && *pwd == '/' ? pwd : NULL;
}

static void dir_push(char **stack, int *n, char *dir)
{
	if (*n == DIRH_MAX) {
		free(stack[0]);
		memmove(stack, stack + 1, (DIRH_MAX - 1) * sizeof(*stack));
		(*n)--;
	}
	stack[(*n)++] = dir;
}

/* At each prompt: a directory left since the last one goes into the history. */
void fdash_dirh_update(void)
{
	const char *pwd = pwd_now();

	if (!pwd || (dirh_here && !strcmp(pwd, dirh_here)))
		return;
	if (dirh_here) {
		dir_push(dirprev, &nprev, dirh_here);
		while (nnext)
			free(dirnext[--nnext]);
	}
	dirh_here = strdup(pwd);
}

static int change_dir(const char *dir)
{
	struct sb line = {0};
	int status;

	sb_str(&line, "command cd -- ");
	sb_quote(&line, dir);
	status = evalstring(line.s, 0);
	free(line.s);
	return status;
}

/* Moves through the history: from one stack onto the other, n times. */
static int dir_step(char **from, int *nfrom, char **to, int *nto, int n, const char *what)
{
	const char *pwd;
	int i;

	if (n < 1)
		sh_error("%s: the step must be a positive number", what);
	if (n > *nfrom)
		sh_error("%s: no %s directory", what, what[0] == 'p' ? "previous" : "next");
	fdash_dirh_update();
	for (i = 0; i < n; i++) {
		dir_push(to, nto, dirh_here);
		dirh_here = from[--*nfrom];
	}
	if (change_dir(dirh_here)) {
		/* put it all back */
		for (i = 0; i < n; i++) {
			dir_push(from, nfrom, dirh_here);
			dirh_here = to[--*nto];
		}
		return 1;
	}
	if ((pwd = pwd_now())) {
		free(dirh_here);
		dirh_here = strdup(pwd);
	}
	return 0;
}

int prevdcmd(int argc, char **argv)
{
	return dir_step(dirprev, &nprev, dirnext, &nnext, argc > 1 ? number(argv[1]) : 1, "prevd");
}

int nextdcmd(int argc, char **argv)
{
	return dir_step(dirnext, &nnext, dirprev, &nprev, argc > 1 ? number(argv[1]) : 1, "nextd");
}

int dirhcmd(int argc, char **argv)
{
	int i;

	fdash_dirh_update();
	for (i = 0; i < nprev; i++)
		out1fmt("%3d) %s\n", nprev - i, dirprev[i]);
	out1fmt("     %s\n", dirh_here ? dirh_here : "?");
	for (i = nnext - 1; i >= 0; i--)
		out1fmt("%3d) %s\n", nnext - i, dirnext[i]);
	return 0;
}

/* Visited directories, newest first, each once and without the current one. */
void dirh_each(gen_fn *fn, void *arg)
{
	char *all[2 * DIRH_MAX];
	int n = 0, i, j;

	for (i = nprev - 1; i >= 0; i--)
		all[n++] = dirprev[i];
	for (i = nnext - 1; i >= 0; i--)
		all[n++] = dirnext[i];
	for (i = 0; i < n; i++) {
		for (j = 0; j < i && strcmp(all[i], all[j]); j++)
			;
		if (j < i || (dirh_here && !strcmp(all[i], dirh_here)))
			continue;
		if (!fn(all[i], strlen(all[i]), "Visited", arg))
			return;
	}
}

struct pick {
	const char *chosen;
	int want, seen;
};

static int pick_dir(const char *dir, size_t len, const char *help, void *arg)
{
	struct pick *p = arg;

	(void)len;
	(void)help;
	if (++p->seen == p->want) {
		p->chosen = dir;
		return 0;
	}
	if (!p->want)
		out1fmt("%3d) %s\n", p->seen, dir);
	return 1;
}

/* cdh DIR changes there; cdh alone lists the visited directories and asks for a number. */
int cdhcmd(int argc, char **argv)
{
	struct pick p = { NULL, 0, 0 };
	char answer[32];
	ssize_t n;

	if (argc > 1)
		return change_dir(argv[1]);
	fdash_dirh_update();
	dirh_each(pick_dir, &p);
	if (!p.seen) {
		out2str("cdh: no other directories visited yet\n");
		return 1;
	}
	out1str("Directory number: ");
	flushall();
	n = read(0, answer, sizeof(answer) - 1);
	if (n <= 0)
		return 1;
	answer[n] = 0;
	p.want = atoi(answer);
	p.seen = 0;
	if (p.want < 1)
		return 1;
	dirh_each(pick_dir, &p);
	if (!p.chosen)
		sh_error("cdh: no directory %d", p.want);
	return change_dir(p.chosen);
}

/* ---------------------------------------------------- universal variables */

/*
 * ~/.config/fdash/universal holds "set NAME VALUE" and "export NAME VALUE"
 * lines. Every fdash on a terminal reads it at startup and again at a prompt
 * when it changed, which costs one stat per prompt.
 */
struct uvar {
	char *name, *value;
	int export;
	struct uvar *next;
};

static struct uvar *uvars;	/* as last read */
static struct stat uvars_seen;

static int uvars_path(struct sb *path)
{
	if (!config_dir(path))
		return 0;
	sb_str(path, "/universal");
	return 1;
}

static void uvars_free(struct uvar *u)
{
	while (u) {
		struct uvar *next = u->next;

		free(u->name);
		free(u->value);
		free(u);
		u = next;
	}
}

static struct uvar *uvar_find(struct uvar *u, const char *name)
{
	while (u && strcmp(u->name, name))
		u = u->next;
	return u;
}

static void unescape(char *s)
{
	char *d = s;

	while (*s) {
		if (*s == '\\' && s[1] == 'n') {
			*d++ = '\n';
			s += 2;
		} else if (*s == '\\' && s[1] == 'x' && s[2] && s[3]) {
			char hex[3] = { s[2], s[3], 0 };

			*d++ = (char)strtol(hex, NULL, 16);
			s += 4;
		} else if (*s == '\\' && s[1]) {
			*d++ = s[1];
			s += 2;
		} else {
			*d++ = *s++;
		}
	}
	*d = 0;
}

static struct uvar *uvars_parse(char *text)
{
	struct uvar *list = NULL, **tail = &list;
	char *line, *next;

	for (line = text; line && *line; line = next) {
		char *name, *value;
		struct uvar *u;
		int export;

		if ((next = strchr(line, '\n')))
			*next++ = 0;
		if (!strncmp(line, "set ", 4))
			export = 0;
		else if (!strncmp(line, "export ", 7))
			export = 1;
		else
			continue;
		name = line + (export ? 7 : 4);
		if (!(value = strchr(name, ' ')))
			continue;
		*value++ = 0;
		if (!goodname(name) || !(u = calloc(1, sizeof(*u))))
			continue;
		unescape(value);
		u->name = strdup(name);
		u->value = strdup(value);
		u->export = export;
		*tail = u;
		tail = &u->next;
	}
	return list;
}

static struct uvar *uvars_read(const char *path)
{
	char *text = read_text(path, 4 << 20);
	struct uvar *list;

	if (!text)
		return NULL;
	list = uvars_parse(text);
	free(text);
	return list;
}

/* Applies what changed between two readings; a value someone set here since stays. */
static void uvars_apply(struct uvar *old, struct uvar *now)
{
	struct uvar *u;

	for (u = now; u; u = u->next) {
		struct uvar *o = uvar_find(old, u->name);

		if (!o || strcmp(o->value, u->value) || o->export != u->export)
			fdash_setvar(u->name, u->value, u->export);
	}
	for (u = old; u; u = u->next) {
		const char *cur;

		if (!uvar_find(now, u->name) && (cur = lookupvar(u->name)) && !strcmp(cur, u->value))
			fdash_setvar(u->name, NULL, 0);
	}
}

static int same_file(const struct stat *a, const struct stat *b)
{
	return a->st_ino == b->st_ino && a->st_size == b->st_size
	       && a->st_mtim.tv_sec == b->st_mtim.tv_sec && a->st_mtim.tv_nsec == b->st_mtim.tv_nsec;
}

/* At startup and at each prompt. */
void fdash_uvars_check(void)
{
	struct sb path = {0};
	struct stat st;
	struct uvar *now;

	if (!uvars_path(&path))
		return;
	if (stat(path.s, &st)) {
		memset(&st, 0, sizeof(st));
		if (!uvars) {
			free(path.s);
			return;
		}
	} else if (same_file(&st, &uvars_seen)) {
		free(path.s);
		return;
	}
	now = uvars_read(path.s);
	uvars_apply(uvars, now);
	uvars_free(uvars);
	uvars = now;
	uvars_seen = st;
	free(path.s);
}

static void sb_uvalue(struct sb *b, const char *s)
{
	for (; *s; s++) {
		unsigned char c = (unsigned char)*s;

		if (c == '\\') {
			sb_str(b, "\\\\");
		} else if (c == '\n') {
			sb_str(b, "\\n");
		} else if (c < 0x20 || c == 0x7f) {
			char hex[8];

			snprintf(hex, sizeof(hex), "\\x%02x", c);
			sb_str(b, hex);
		} else {
			sb_chr(b, (char)c);
		}
	}
}

/*
 * Changes the file under a lock, so two shells setting different variables at
 * once both get theirs, and replaces it atomically for the readers.
 */
static int uvars_write(const char *name, const char *value, int export)
{
	struct sb path = {0}, lock = {0}, tmp = {0}, out = {0};
	struct uvar *list, **up, *u;
	struct stat st;
	int lfd, ok = 0;
	FILE *f;

	if (!uvars_path(&path))
		sh_error("universal: no home directory");
	sb_str(&lock, path.s);
	sb_str(&lock, ".lock");
	{
		char *slash = strrchr(path.s, '/');

		*slash = 0;
		mkdirs(path.s);
		*slash = '/';
	}
	lfd = open(lock.s, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (lfd < 0 || flock(lfd, LOCK_EX))
		goto out;
	list = uvars_read(path.s);
	for (up = &list; *up && strcmp((*up)->name, name); up = &(*up)->next)
		;
	if (*up && !value) {
		u = *up;
		*up = u->next;
		u->next = NULL;
		uvars_free(u);
	} else if (value) {
		if (!*up && (*up = calloc(1, sizeof(**up))))
			(*up)->name = strdup(name);
		if ((u = *up)) {
			free(u->value);
			u->value = strdup(value);
			u->export = export;
		}
	}
	sb_str(&out, "# fdash universal variables, kept by the universal builtin.\n");
	for (u = list; u; u = u->next) {
		sb_str(&out, u->export ? "export " : "set ");
		sb_str(&out, u->name);
		sb_chr(&out, ' ');
		sb_uvalue(&out, u->value);
		sb_chr(&out, '\n');
	}
	sb_str(&tmp, path.s);
	sb_str(&tmp, ".new");
	if ((f = fopen(tmp.s, "w"))) {
		ok = fwrite(out.s, 1, out.len, f) == out.len;
		ok = fclose(f) == 0 && ok && rename(tmp.s, path.s) == 0;
		if (!ok)
			unlink(tmp.s);
	}
	/* this shell already has the change: no need to read it back at the prompt */
	if (ok && stat(path.s, &st) == 0) {
		uvars_free(uvars);
		uvars = list;
		uvars_seen = st;
	} else {
		uvars_free(list);
	}
out:
	if (lfd >= 0)
		close(lfd);
	free(path.s);
	free(lock.s);
	free(tmp.s);
	free(out.s);
	if (!ok)
		sh_error("universal: cannot write the variables file: %s", strerror(errno));
	return ok;
}

/*
 * universal [-x] NAME=VALUE...   sets them here and in every running fdash
 * universal [-x] NAME...         makes the current values universal
 * universal -e NAME...           forgets them
 * universal                      lists them
 */
int universalcmd(int argc, char **argv)
{
	int export = 0, erase = 0, c;
	char **ap;

	while ((c = nextopt("xe")) != '\0') {
		if (c == 'x')
			export = 1;
		else
			erase = 1;
	}
	fdash_uvars_check();
	if (!*argptr) {
		struct uvar *u;

		for (u = uvars; u; u = u->next)
			out1fmt("universal %s%s=%s\n", u->export ? "-x " : "", u->name, single_quote(u->value));
		return 0;
	}
	for (ap = argptr; *ap; ap++) {
		char *eq = strchr(*ap, '=');
		const char *value;
		struct sb name = {0};

		sb_add(&name, *ap, eq ? (size_t)(eq - *ap) : strlen(*ap));
		if (!goodname(name.s)) {
			free(name.s);
			sh_error("universal: %s: bad variable name", *ap);
		}
		if (erase) {
			uvars_write(name.s, NULL, 0);
			fdash_setvar(name.s, NULL, 0);
		} else {
			char *v;

			value = eq ? eq + 1 : lookupvar(name.s);
			if (!value) {
				free(name.s);
				sh_error("universal: %s is not set", *ap);
			}
			v = strdup(value);
			if (!v || !fdash_setvar(name.s, v, export)) {
				free(v);
				free(name.s);
				sh_error("universal: %s is read-only", *ap);
			}
			uvars_write(name.s, v, export);
			free(v);
		}
		free(name.s);
	}
	return 0;
}
