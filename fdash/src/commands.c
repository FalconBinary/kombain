/*
 * fdash builtins beyond the line editor: directory history, universal
 * variables and function sources. They are POSIX-named commands, so scripts
 * that never call them see plain dash.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <dirent.h>
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
#include "main.h"
#include "memalloc.h"
#include "mystring.h"
#include "options.h"
#include "output.h"
#include "parser.h"
#include "var.h"

#include "fdash.h"
#include "isocline.h"
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

/* -------------------------------------------------------- function sources */

/*
 * dash keeps a function as a parse tree, so fdash keeps its text too: the
 * parser records what it reads from the closing parenthesis to the end of the
 * body, in interactive shells only (config.sh included). defun() then finds
 * the text by the node it was recorded for.
 */
struct fsource {
	const void *node;
	char *name, *text;
	int linno;
	struct fsource *next;
};

#define PENDING_MAX 16

void *fdash_rec_file;		/* the input being recorded, or NULL */
static int rec_depth;
static struct sb rec;
static size_t rec_mark;		/* where the last token began */
static struct fsource *pending, *sources;

void fdash_rec_reset(void)
{
	rec_depth = 0;
	fdash_rec_file = NULL;
}

void fdash_rec_start(void *file)
{
	if (!iflag || rec_depth++)
		return;		/* a function inside a function goes with the outer one */
	sb_clear(&rec);
	rec_mark = 0;
	fdash_rec_file = file;
}

void fdash_rec_char(int c)
{
	if (c >= -128)
		sb_chr(&rec, (char)c);
}

void fdash_rec_unget(int n)
{
	while (n-- > 0 && rec.len)
		rec.s[--rec.len] = 0;
}

void fdash_rec_mark(void)
{
	rec_mark = rec.len;
}

static void fsource_free(struct fsource *f)
{
	free(f->name);
	free(f->text);
	free(f);
}

/* The body is read; the token after it (pushed back for the next command) is not part of it. */
void fdash_rec_stop(const void *node, const char *name, int linno, int pushback)
{
	struct fsource *f, **fp;
	const char *body;
	size_t n;
	int count = 0;

	if (!rec_depth || --rec_depth)
		return;
	fdash_rec_file = NULL;
	if (pushback && rec_mark <= rec.len) {
		rec.len = rec_mark;
		rec.s[rec.len] = 0;
	}
	for (body = rec.s; *body == ' ' || *body == '\t' || *body == '\n'; body++)
		;
	n = strlen(body);
	while (n && strchr(" \t\n;&", body[n - 1]))
		n--;
	if (!n || !(f = calloc(1, sizeof(*f))))
		return;
	{
		struct sb text = {0};

		sb_str(&text, name);
		sb_str(&text, "() ");
		sb_add(&text, body, n);
		sb_chr(&text, '\n');
		f->text = text.s;
	}
	f->node = node;
	f->name = strdup(name);
	f->linno = linno;
	f->next = pending;
	pending = f;
	/* a definition that never ran is forgotten after a while */
	for (fp = &pending; *fp; fp = &(*fp)->next) {
		if (++count > PENDING_MAX) {
			while ((f = *fp)) {
				*fp = f->next;
				fsource_free(f);
			}
			break;
		}
	}
}

static struct fsource **source_find(const char *name)
{
	struct fsource **fp;

	for (fp = &sources; *fp && strcmp((*fp)->name, name); fp = &(*fp)->next)
		;
	return fp;
}

/* defun() and unset -f: the function now has the recorded text, or none. */
void fdash_defun(const void *node, const char *name, int linno)
{
	struct fsource **fp = source_find(name), *p;

	if (*fp) {
		struct fsource *old = *fp;

		*fp = old->next;
		fsource_free(old);
	}
	if (!node)
		return;
	for (p = pending; p; p = p->next) {
		if (p->node == node && p->linno == linno && !strcmp(p->name, name)) {
			struct fsource *f = calloc(1, sizeof(*f));

			if (f && (f->name = strdup(name)) && (f->text = strdup(p->text))) {
				f->next = sources;
				sources = f;
			} else if (f) {
				fsource_free(f);
			}
			return;
		}
	}
}

static int functions_path(struct sb *path, const char *name)
{
	if (!config_dir(path))
		return 0;
	sb_str(path, "/functions/");
	sb_str(path, name);
	sb_str(path, ".sh");
	return 1;
}

/* ~/.config/fdash/functions/NAME.sh, if it is a regular file of the user's. */
int fdash_autoload_exists(const char *name)
{
	struct sb path = {0};
	struct stat st;
	int ok;

	ok = goodname(name) && functions_path(&path, name) && stat(path.s, &st) == 0
	     && S_ISREG(st.st_mode) && st.st_uid == geteuid();
	free(path.s);
	return ok;
}

/* exec.c, when a command is not found: a saved function loads in interactive shells. */
int fdash_autoload(const char *name)
{
	static int loading;
	struct sb path = {0};
	int ok = 0;

	if (loading || !fdash_active() || !fdash_autoload_exists(name))
		return 0;
	loading = 1;
	functions_path(&path, name);
	readcmdfile(path.s);
	loading = 0;
	ok = fdash_isfunction(name);
	free(path.s);
	return ok;
}

void fdash_listautoload(void (*fn)(const char *, void *), void *arg)
{
	struct sb dir = {0};
	struct dirent *e;
	DIR *d;

	if (!config_dir(&dir))
		return;
	sb_str(&dir, "/functions");
	if ((d = opendir(dir.s))) {
		while ((e = readdir(d))) {
			size_t n = strlen(e->d_name);

			if (n > 3 && !strcmp(e->d_name + n - 3, ".sh") && e->d_name[0] != '.') {
				e->d_name[n - 3] = 0;
				if (goodname(e->d_name))
					fn(e->d_name, arg);
			}
		}
		closedir(d);
	}
	free(dir.s);
}

static void print_name(const char *name, void *arg)
{
	(void)arg;
	out1fmt("%s\n", name);
}

/* functions: their names; functions NAME...: their text. */
int functionscmd(int argc, char **argv)
{
	int i, status = 0;

	if (argc < 2) {
		fdash_listfunctions(print_name, NULL);
		return 0;
	}
	for (i = 1; i < argc; i++) {
		struct fsource **fp = source_find(argv[i]);

		if (!fdash_isfunction(argv[i]) && !fdash_autoload(argv[i])) {
			outfmt(out2, "functions: %s: no such function\n", argv[i]);
			status = 1;
		} else if (*(fp = source_find(argv[i]))) {
			out1str((*fp)->text);
		} else {
			outfmt(out2, "functions: %s: defined where fdash did not keep the text\n", argv[i]);
			status = 1;
		}
	}
	return status;
}

static int write_file(const char *path, const char *text)
{
	struct sb tmp = {0};
	FILE *f;
	int ok = 0;

	sb_str(&tmp, path);
	sb_str(&tmp, ".new");
	if ((f = fopen(tmp.s, "w"))) {
		ok = fputs(text, f) >= 0;
		ok = fclose(f) == 0 && ok && rename(tmp.s, path) == 0;
		if (!ok)
			unlink(tmp.s);
	}
	free(tmp.s);
	return ok;
}

/* funcsave NAME...: into ~/.config/fdash/functions, where they load on first use. */
int funcsavecmd(int argc, char **argv)
{
	struct sb path = {0};
	int i, status = 0;

	if (argc < 2)
		sh_error("usage: funcsave name...");
	for (i = 1; i < argc; i++) {
		struct fsource **fp = source_find(argv[i]);

		if (!*fp || !functions_path(&path, argv[i])) {
			outfmt(out2, "funcsave: %s: %s\n", argv[i],
			       fdash_isfunction(argv[i]) ? "its text was not kept" : "no such function");
			status = 1;
			continue;
		}
		{
			char *slash = strrchr(path.s, '/');

			*slash = 0;
			mkdirs(path.s);
			*slash = '/';
		}
		if (write_file(path.s, (*fp)->text)) {
			out1fmt("funcsave: wrote %s\n", path.s);
		} else {
			outfmt(out2, "funcsave: cannot write %s\n", path.s);
			status = 1;
		}
	}
	free(path.s);
	return status;
}

/*
 * funced NAME: the function in $VISUAL or $EDITOR, defined again from what is
 * saved. A new name starts from an empty function.
 */
int funcedcmd(int argc, char **argv)
{
	struct sb text = {0}, tmp = {0}, line = {0};
	struct jmploc jmploc, *volatile savehandler = handler;
	const char *name, *dir = lookupvar("TMPDIR");
	struct fsource **fp;
	volatile int status = 1;
	int fd, failed;

	if (argc != 2 || !goodname(argv[1]))
		sh_error("usage: funced name");
	name = argv[1];
	if (!fdash_isfunction(name))
		fdash_autoload(name);
	if (*(fp = source_find(name))) {
		sb_str(&text, (*fp)->text);
	} else if (fdash_isfunction(name)) {
		sh_error("funced: %s was defined where fdash did not keep its text", name);
	} else {
		sb_str(&text, name);
		sb_str(&text, "() {\n\t\n}\n");
	}
	sb_str(&tmp, dir && *dir == '/' ? dir : "/tmp");
	sb_str(&tmp, "/fdash-");
	sb_str(&tmp, name);
	sb_str(&tmp, ".XXXXXX.sh");
	if ((fd = mkstemps(tmp.s, 3)) < 0) {
		free(text.s);
		free(tmp.s);
		sh_error("funced: cannot make a temporary file");
	}
	failed = write(fd, text.s, text.len) != (ssize_t)text.len;
	close(fd);
	free(text.s);
	if (!setjmp(jmploc.loc)) {
		handler = &jmploc;
		if (!failed) {
			sb_str(&line, "${VISUAL:-${EDITOR:-vi}} ");
			sb_quote(&line, tmp.s);
			if ((status = evalstring(line.s, 0)) == 0) {
				sb_clear(&line);
				sb_str(&line, ". ");
				sb_quote(&line, tmp.s);
				status = evalstring(line.s, 0);
			}
		}
		failed = 0;
	} else {
		failed = 1;
	}
	handler = savehandler;
	unlink(tmp.s);
	free(tmp.s);
	free(line.s);
	if (failed)
		longjmp(handler->loc, 1);
	if (!status && !fdash_isfunction(name)) {
		outfmt(out2, "funced: what was saved does not define %s\n", name);
		status = 1;
	}
	return status;
}

/* ------------------------------------------------------ command not found */

/* A program on PATH, as a path. */
static int on_path(const char *prog, struct sb *out)
{
	const char *p = pathval();

	for (;;) {
		const char *end = strchr(p, ':');
		size_t n = end ? (size_t)(end - p) : strlen(p);

		sb_clear(out);
		sb_add(out, p, n);
		sb_chr(out, '/');
		sb_str(out, prog);
		if (n && *out->s == '/' && access(out->s, X_OK) == 0)
			return 1;
		if (!end)
			return 0;
		p = end + 1;
	}
}

static int call_handler(int argc, char **argv)
{
	struct sb line = {0};
	int i, status;

	sb_str(&line, "fdash_command_not_found");
	for (i = 0; i < argc; i++) {
		sb_chr(&line, ' ');
		sb_quote(&line, argv[i]);
	}
	status = evalstring(line.s, 0);
	free(line.s);
	return status;
}

/*
 * After "not found" in an interactive shell: a function fdash_command_not_found
 * takes over if there is one; otherwise xlocate (from xtools) names the Void
 * packages that have the command.
 */
int fdash_not_found(int argc, char **argv)
{
	static int told;
	struct sb prog = {0}, out = {0}, pattern = {0}, db = {0}, pkgs = {0};
	const char *name = argv[0], *p;
	char *xargv[4];
	struct stackmark mark;
	int found = 0;

	if (fdash_isfunction("fdash_command_not_found"))
		return call_handler(argc, argv);
	if (!*name || strchr(name, '/') || !on_path("xlocate", &prog))
		goto out;
	p = lookupvar("XDG_CACHE_HOME");
	if (p && *p == '/') {
		sb_str(&db, p);
	} else if ((p = lookupvar("HOME"))) {
		sb_str(&db, p);
		sb_str(&db, "/.cache");
	}
	sb_str(&db, "/xlocate.git");
	if (!is_dir(db.s)) {
		if (!told++)
			outfmt(out2, "fdash: xlocate -S downloads the index that tells which package has %s\n", name);
		goto out;
	}
	sb_str(&pattern, "^/usr/bin/");
	for (p = name; *p; p++) {
		if (strchr(".[]*^$\\", *p))
			sb_chr(&pattern, '\\');
		sb_chr(&pattern, *p);
	}
	sb_chr(&pattern, '$');
	xargv[0] = prog.s;
	xargv[1] = "-e";
	xargv[2] = pattern.s;
	xargv[3] = NULL;
	setstackmark(&mark);
	run_capture(xargv, listvars(VEXPORT, VUNSET, NULL), 5000, &out, 1 << 16);
	popstackmark(&mark);
	/* lines of "pkgname-version_revision  /usr/bin/name" */
	for (p = out.s; p && *p; ) {
		const char *eol = strchr(p, '\n'), *end = p + strcspn(p, " \t\n");
		const char *dash = end;
		size_t i;

		while (dash > p && *dash != '-')
			dash--;
		if (dash > p) {
			for (i = 0; p + i < dash && !control_len(p + i); i++)
				;
			if (p + i == dash && found < 5) {
				if (found++)
					sb_str(&pkgs, " ");
				sb_add(&pkgs, p, (size_t)(dash - p));
			}
		}
		p = eol ? eol + 1 : NULL;
	}
	if (found == 1)
		outfmt(out2, "%s is in the package %s: doas xbps-install %s\n", name, pkgs.s, pkgs.s);
	else if (found)
		outfmt(out2, "%s is in these packages: %s\n", name, pkgs.s);
out:
	free(prog.s);
	free(out.s);
	free(pattern.s);
	free(db.s);
	free(pkgs.s);
	return 127;
}

/* --------------------------------------------------------------------- fc */

/* History numbers count from 1, the oldest; the line running fc is not one of them. */
static long fc_count(void)
{
	long n = ic_history_count() - (fdash_line_saved() ? 1 : 0);

	return n > 0 ? n : 0;
}

static const char *fc_entry(long num)
{
	return ic_history_get(fc_count() - num + (fdash_line_saved() ? 1 : 0));
}

/* A number (negative: back from the newest) or the newest command starting with the text. */
static long fc_find(const char *spec)
{
	long n = fc_count(), v, i;
	const char *p = spec + (*spec == '-' || *spec == '+');

	if (*p && strspn(p, "0123456789") == strlen(p)) {
		v = atol(spec);
		if (v < 0)
			v = n + 1 + v;
		return v < 1 ? 1 : v > n ? n : v;
	}
	for (i = n; i >= 1; i--) {
		const char *e = fc_entry(i);

		if (e && !strncmp(e, spec, strlen(spec)))
			return i;
	}
	sh_error("fc: no command starts with %s", spec);
	return 0;
}

/* What fc runs replaces it in the history, as POSIX asks. */
static int fc_run(const char *cmd, int show)
{
	if (show)
		out1fmt("%s\n", cmd);
	flushall();
	if (fdash_line_saved())
		ic_history_remove_last();
	ic_history_add(cmd);
	return evalstring((char *)cmd, 0);
}

/*
 * fc -l [-nr] [first [last]]     lists
 * fc -s [old=new] [first]        runs one again, changed
 * fc [-r] [-e editor] [first [last]]  edits some and runs them
 */
int fccmd(int argc, char **argv)
{
	const char *editor = NULL, *ops[2] = { NULL, NULL };
	int list = 0, nonum = 0, rev = 0, again = 0, nops = 0, i;
	long first, last, n;

	if (!fdash_active() || !ic_history_count())
		sh_error("fc: no history");
	for (i = 1; i < argc; i++) {
		const char *a = argv[i];

		if (!strcmp(a, "--")) {
			i++;
			break;
		}
		if (a[0] != '-' || !a[1] || strspn(a + 1, "0123456789") == strlen(a + 1))
			break;
		for (a++; *a; a++) {
			switch (*a) {
			case 'l': list = 1; break;
			case 'n': nonum = 1; break;
			case 'r': rev = 1; break;
			case 's': again = 1; break;
			case 'e':
				editor = a[1] ? a + 1 : argv[++i];
				if (!editor)
					sh_error("fc: -e needs an editor");
				a = " ";	/* the rest was the editor */
				break;
			default:
				sh_error("usage: fc -l [-nr] [first [last]] | fc -s [old=new] [first] | fc [-r] [-e editor] [first [last]]");
			}
			if (*a == ' ')
				break;
		}
	}
	if (editor && !strcmp(editor, "-"))
		again = 1;
	n = fc_count();
	if (!n)
		sh_error("fc: no history");
	if (again) {
		struct sb cmd = {0};
		const char *e, *old = NULL, *eq = NULL;
		int status;

		if (i < argc && (eq = strchr(argv[i], '=')))
			old = argv[i++];
		if (!(e = fc_entry(i < argc ? fc_find(argv[i]) : n)))
			sh_error("fc: no such command");
		sb_str(&cmd, e);
		if (old && eq > old) {
			/* the first old in it becomes new */
			struct sb pat = {0};
			const char *at;

			sb_add(&pat, old, (size_t)(eq - old));
			if ((at = strstr(e, pat.s))) {
				sb_clear(&cmd);
				sb_add(&cmd, e, (size_t)(at - e));
				sb_str(&cmd, eq + 1);
				sb_str(&cmd, at + pat.len);
			}
			free(pat.s);
		}
		status = fc_run(cmd.s, 1);
		free(cmd.s);
		return status;
	}
	while (i < argc && nops < 2)
		ops[nops++] = argv[i++];
	if (list) {
		first = ops[0] ? fc_find(ops[0]) : (n > 16 ? n - 15 : 1);
		last = ops[1] ? fc_find(ops[1]) : n;
	} else {
		first = ops[0] ? fc_find(ops[0]) : n;
		last = ops[1] ? fc_find(ops[1]) : first;
	}
	if (first > last) {
		long t = first;

		first = last;
		last = t;
		rev = !rev;
	}
	if (list) {
		long k;

		for (k = 0; k <= last - first; k++) {
			long num = rev ? last - k : first + k;
			const char *e = fc_entry(num);

			if (nonum)
				out1fmt("\t%s\n", e ? e : "");
			else
				out1fmt("%ld\t%s\n", num, e ? e : "");
		}
		return 0;
	}
	{
		struct sb text = {0}, tmp = {0}, line = {0};
		const char *dir = lookupvar("TMPDIR");
		char *edited;
		long k;
		int fd, status;

		for (k = 0; k <= last - first; k++) {
			const char *e = fc_entry(rev ? last - k : first + k);

			sb_str(&text, e ? e : "");
			sb_chr(&text, '\n');
		}
		sb_str(&tmp, dir && *dir == '/' ? dir : "/tmp");
		sb_str(&tmp, "/fdash-fc.XXXXXX.sh");
		if ((fd = mkstemps(tmp.s, 3)) < 0)
			sh_error("fc: cannot make a temporary file");
		status = write(fd, text.s, text.len) == (ssize_t)text.len ? 0 : 1;
		close(fd);
		free(text.s);
		if (!status) {
			if (editor) {
				sb_str(&line, editor);
			} else {
				sb_str(&line, "${FCEDIT:-${VISUAL:-${EDITOR:-vi}}}");
			}
			sb_chr(&line, ' ');
			sb_quote(&line, tmp.s);
			status = evalstring(line.s, 0);
		}
		edited = status ? NULL : read_text(tmp.s, 1 << 20);
		unlink(tmp.s);
		free(tmp.s);
		free(line.s);
		if (!edited)
			return status ? status : 1;
		{
			size_t len = strlen(edited);

			while (len && edited[len - 1] == '\n')
				edited[--len] = 0;
		}
		status = *edited ? fc_run(edited, 1) : 0;
		free(edited);
		return status;
	}
}
