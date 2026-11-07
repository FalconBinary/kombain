/* Tables in pipelines, after Nushell. SPDX-License-Identifier: GPL-3.0-or-later */

/*
 * A table travels between commands as text, tab-separated, its first line
 * the names of the columns, so every other program can read and write it:
 *
 *     lsx | where size > 1mb | sort-by -r modified | first 5
 *
 * Whichever command writes to a terminal draws the table instead, aligned,
 * with sizes in KiB and MiB, as Nushell shows its own. `from` reads CSV, JSON
 * and space-separated columns into a table, `to` writes CSV and JSON.
 */

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <grp.h>
#include <pwd.h>
#include <regex.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <wchar.h>

#include "shell.h"
#include "error.h"
#include "memalloc.h"
#include "output.h"
#include "options.h"
#include "fdash.h"

struct table {
	char **cell; /* row-major, row 0 the names */
	int rows;
	int cols;
	int cap;
	char *text; /* what the cells point into */
};

static void addrow(struct table *t, char **fields, int n)
{
	if (t->rows == 0 && t->cols == 0)
		t->cols = n;
	if ((t->rows + 1) * t->cols > t->cap) {
		t->cap = ((t->rows + 1) * t->cols) * 2 + 16;
		t->cell = ckrealloc(t->cell, t->cap * sizeof(char *));
	}
	for (int i = 0; i < t->cols; i++)
		t->cell[t->rows * t->cols + i] = i < n ? fields[i] : "";
	t->rows++;
}

static char *cellat(struct table *t, int row, int col)
{
	return t->cell[row * t->cols + col];
}

static char *readall(int fd)
{
	size_t len = 0, cap = 4096;
	char *buf = ckmalloc(cap);
	ssize_t n;

	for (;;) {
		if (len + 1 >= cap)
			buf = ckrealloc(buf, cap *= 2);
		n = read(fd, buf + len, cap - len - 1);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			break;
		len += n;
	}
	buf[len] = 0;
	return buf;
}

/* Tab-separated, or columns of words when no line has a tab. */
static void parse(struct table *t, char *text)
{
	int tabs = strchr(text, '\t') != NULL;
	char *line, *next;
	char **fields = NULL;
	int cap = 0;

	t->text = text;
	for (line = text; *line; line = next) {
		int n = 0;
		char *p;

		next = strchr(line, '\n');
		if (next)
			*next++ = 0;
		else
			next = line + strlen(line);
		if (*line == 0 || (*line == '\r' && line[1] == 0))
			continue;
		for (p = line;;) {
			char *end;

			if (n + 1 > cap)
				fields = ckrealloc(fields, (cap = cap * 2 + 8) * sizeof(char *));
			if (!tabs) {
				while (*p == ' ')
					p++;
				/* the last column takes the rest, a command line with its spaces */
				if (t->cols && n == t->cols - 1) {
					fields[n++] = p;
					break;
				}
			}
			fields[n++] = p;
			end = tabs ? strchr(p, '\t') : strchr(p, ' ');
			if (!end)
				break;
			*end = 0;
			p = end + 1;
			if (!tabs && !*p)
				break;
		}
		if (n && fields[n - 1][0] && fields[n - 1][strlen(fields[n - 1]) - 1] == '\r')
			fields[n - 1][strlen(fields[n - 1]) - 1] = 0;
		addrow(t, fields, n);
	}
	ckfree(fields);
}

static void readtable(struct table *t)
{
	memset(t, 0, sizeof(*t));
	parse(t, readall(0));
}

static int column(struct table *t, const char *name)
{
	for (int i = 0; i < t->cols; i++)
		if (!strcmp(cellat(t, 0, i), name))
			return i;
	sh_error("no column %s", name);
	return -1;
}

/* ---------------------------------------------------------------- numbers */

/* A number, with a unit of size or of time: 1.5mb, 300ms, 2min, 10KiB. */
static int number(const char *s, double *out)
{
	static const struct {
		const char *unit;
		double factor;
	} units[] = {
		{ "b", 1 }, { "kb", 1e3 }, { "k", 1e3 }, { "kib", 1024. }, { "mb", 1e6 }, { "m", 1e6 },
		{ "mib", 1048576. }, { "gb", 1e9 }, { "g", 1e9 }, { "gib", 1073741824. }, { "tb", 1e12 },
		{ "tib", 1099511627776. }, { "ns", 1e-9 }, { "us", 1e-6 }, { "ms", 1e-3 }, { "s", 1 },
		{ "sec", 1 }, { "min", 60 }, { "h", 3600 }, { "hr", 3600 }, { "d", 86400 },
		{ "day", 86400 }, { "w", 604800 }, { "wk", 604800 }, { "%", 1 },
	};
	char *end;
	double v;

	while (*s == ' ')
		s++;
	if (!*s || !(isdigit((unsigned char)*s) || ((*s == '-' || *s == '+' || *s == '.') && s[1])))
		return 0;
	errno = 0;
	v = strtod(s, &end);
	if (end == s || errno)
		return 0;
	while (*end == ' ')
		end++;
	if (*end) {
		size_t i;

		for (i = 0; i < sizeof(units) / sizeof(units[0]); i++)
			if (!strcasecmp(end, units[i].unit))
				break;
		if (i == sizeof(units) / sizeof(units[0]))
			return 0;
		v *= units[i].factor;
	}
	*out = v;
	return 1;
}

static int compare(const char *a, const char *b)
{
	double x, y;

	if (number(a, &x) && number(b, &y))
		return x < y ? -1 : x > y;
	return strverscmp(a, b);
}

/* ---------------------------------------------------------------- drawing */

static int width(const char *s)
{
	mbstate_t mbs = { 0 };
	int w = 0;
	size_t n = strlen(s);

	while (n) {
		wchar_t wc;
		size_t ml = mbrtowc(&wc, s, n, &mbs);
		int cw;

		if (ml == (size_t)-1 || ml == (size_t)-2 || ml == 0) {
			ml = 1;
			cw = 1;
			memset(&mbs, 0, sizeof(mbs));
		} else {
			cw = wcwidth(wc);
			if (cw < 0)
				cw = 1;
		}
		w += cw;
		s += ml;
		n -= ml;
	}
	return w;
}

/* The bytes of s that fit in w columns. */
static size_t fit(const char *s, int w)
{
	mbstate_t mbs = { 0 };
	size_t n = strlen(s), at = 0;

	while (at < n) {
		wchar_t wc;
		size_t ml = mbrtowc(&wc, s + at, n - at, &mbs);
		int cw = 1;

		if (ml == (size_t)-1 || ml == (size_t)-2 || ml == 0) {
			ml = 1;
			memset(&mbs, 0, sizeof(mbs));
		} else if ((cw = wcwidth(wc)) < 0) {
			cw = 1;
		}
		if (cw > w)
			break;
		w -= cw;
		at += ml;
	}
	return at;
}

static int humanized(const char *name)
{
	return !strcmp(name, "size") || !strcmp(name, "mem");
}

static void human(char *buf, size_t len, const char *cell)
{
	static const char *const unit[] = { "B", "KiB", "MiB", "GiB", "TiB" };
	double v;
	int u = 0;

	if (!number(cell, &v) || strspn(cell, "0123456789") != strlen(cell)) {
		snprintf(buf, len, "%s", cell);
		return;
	}
	while (v >= 1024 && u < 4) {
		v /= 1024;
		u++;
	}
	if (u == 0)
		snprintf(buf, len, "%.0f B", v);
	else
		snprintf(buf, len, v < 10 ? "%.1f %s" : "%.0f %s", v, unit[u]);
}

static int terminal(int fd)
{
	return isatty(fd);
}

static int columns(void)
{
	struct winsize ws;

	if (ioctl(1, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0)
		return ws.ws_col;
	return 80;
}

/* What a cell shows: sizes in KiB and MiB, nothing that moves the cursor. */
static void shown(char *buf, size_t len, struct table *t, int row, int col)
{
	const char *cell = cellat(t, row, col);
	char *p;

	if (row > 0 && humanized(cellat(t, 0, col)))
		human(buf, len, cell);
	else
		snprintf(buf, len, "%s", cell);
	for (p = buf; *p; p++)
		if ((unsigned char)*p < 0x20 || *p == 0x7f)
			*p = '?';
}

static void draw(struct table *t)
{
	int *w, total, room = columns(), indexw;
	char buf[512];
	int numeric[256];
	int name = -1, type = -1;

	if (!t->rows)
		return;
	w = ckmalloc(t->cols * sizeof(int));
	indexw = snprintf(buf, sizeof(buf), "%d", t->rows - 2 > 0 ? t->rows - 2 : 0);
	for (int c = 0; c < t->cols; c++) {
		w[c] = 0;
		numeric[c & 255] = t->rows > 1;
		for (int r = 0; r < t->rows; r++) {
			int cw;
			double v;

			shown(buf, sizeof(buf), t, r, c);
			cw = width(buf);
			if (cw > w[c])
				w[c] = cw;
			if (r > 0 && *cellat(t, r, c) && !number(cellat(t, r, c), &v))
				numeric[c & 255] = 0;
		}
		if (!strcmp(cellat(t, 0, c), "name"))
			name = c;
		if (!strcmp(cellat(t, 0, c), "type"))
			type = c;
	}
	/* too wide: the widest columns give way, a little at a time */
	for (;;) {
		int widest = 0;

		total = indexw + 2;
		for (int c = 0; c < t->cols; c++)
			total += w[c] + 2;
		if (total <= room)
			break;
		for (int c = 1; c < t->cols; c++)
			if (w[c] > w[widest])
				widest = c;
		if (w[widest] <= 8)
			break;
		w[widest]--;
	}
	for (int r = 0; r < t->rows; r++) {
		if (r == 0)
			out1fmt("\033[1;32m%*s\033[0m  ", indexw, "#");
		else
			out1fmt("\033[2m%*d\033[0m  ", indexw, r - 1);
		for (int c = 0; c < t->cols; c++) {
			size_t keep;
			int cw, pad;
			const char *color = "";

			shown(buf, sizeof(buf), t, r, c);
			keep = fit(buf, w[c]);
			if (keep < strlen(buf)) {
				keep = fit(buf, w[c] - 1);
				strcpy(buf + keep, "~");
				keep++;
			}
			buf[keep] = 0;
			cw = width(buf);
			pad = w[c] - cw;
			if (r == 0)
				color = "\033[1;32m";
			else if (c == name && type >= 0 && !strcmp(cellat(t, r, type), "dir"))
				color = "\033[1;34m";
			else if (c == name && type >= 0 && !strcmp(cellat(t, r, type), "link"))
				color = "\033[36m";
			if (numeric[c & 255] && r > 0)
				out1fmt("%*s", pad, "");
			out1fmt("%s%s%s", color, buf, *color ? "\033[0m" : "");
			if (c < t->cols - 1)
				out1fmt("%*s", (numeric[c & 255] && r > 0 ? 0 : pad) + 2, "");
		}
		out1c('\n');
	}
	ckfree(w);
}

static void writetsv(struct table *t, int from, int to)
{
	for (int r = from; r < to; r++)
		for (int c = 0; c < t->cols; c++)
			out1fmt("%s%c", cellat(t, r, c), c == t->cols - 1 ? '\n' : '\t');
}

/* The rows chosen, after the names: drawn on a terminal, else as text. */
static void emit(struct table *t, int *rows, int n)
{
	struct table out = { 0 };

	addrow(&out, &t->cell[0], t->cols);
	for (int i = 0; i < n; i++)
		addrow(&out, &t->cell[rows[i] * t->cols], t->cols);
	if (terminal(1))
		draw(&out);
	else
		writetsv(&out, 0, out.rows);
	ckfree(out.cell);
}

static void emitall(struct table *t)
{
	if (terminal(1))
		draw(t);
	else
		writetsv(t, 0, t->rows);
}

/* ---------------------------------------------------------------- commands */

/*
 * last, reject and from are also programs: util-linux's last, CUPS's reject.
 * With nothing piped in, the program of that name runs instead.
 */
static int external(char **argv)
{
	pid_t pid;
	int status;

	flushall();
	pid = fork();
	if (pid < 0)
		sh_error("fork: %s", strerror(errno));
	if (pid == 0) {
		execvp(argv[0], argv);
		sh_warnx("%s: %s", argv[0], strerror(errno));
		_exit(127);
	}
	while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
		;
	return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

int tablecmd(int argc, char **argv)
{
	struct table t;

	readtable(&t);
	draw(&t);
	return 0;
}

/*
 * where COLUMN OP VALUE, or the three in one quoted word: where 'size > 1mb'.
 * Unquoted, > and < are redirections to the shell, so -gt and -lt are here
 * too, as test has them, and gt, lt and the rest.
 */
int wherecmd(int argc, char **argv)
{
	struct table t;
	int *rows, n = 0, col, op, negate = 0;
	regex_t re;
	double want = 0;
	int wantnum;
	const char *value;
	char *words[3];
	static const char *const ops[] = {
		"==", "!=", "<", "<=", ">", ">=", "=~", "!~", "contains",
		"-eq", "-ne", "-lt", "-le", "-gt", "-ge", NULL, NULL, "has",
		"eq", "ne", "lt", "le", "gt", "ge", NULL,
	};
	static const char usage[] = "usage: where COLUMN OP VALUE, or where 'COLUMN OP VALUE'; "
				    "OP is == != < <= > >= (or -eq -ne -lt -le -gt -ge) =~ !~ contains";

	if (argc == 2) {
		/* one word: split it in three, the value keeps its spaces */
		char *p = savestr(argv[1]);

		for (int i = 0; i < 3; i++) {
			while (*p == ' ')
				p++;
			words[i] = p;
			if (i < 2 && (p = strchr(p, ' ')))
				*p++ = 0;
			else if (i < 2)
				sh_error("%s", usage);
		}
		argv = words - 1;
		argc = 4;
	}
	if (argc != 4)
		sh_error("%s", usage);
	for (op = 0; op < (int)(sizeof(ops) / sizeof(ops[0])); op++)
		if (ops[op] && !strcmp(ops[op], argv[2]))
			break;
	if (op == (int)(sizeof(ops) / sizeof(ops[0])))
		sh_error("%s: not an operator. %s", argv[2], usage);
	op %= 9;
	value = argv[3];
	wantnum = number(value, &want);
	if (op == 6 || op == 7) {
		int rc = regcomp(&re, value, REG_EXTENDED | REG_NOSUB);

		if (rc) {
			char msg[128];

			regerror(rc, &re, msg, sizeof(msg));
			sh_error("%s: %s", value, msg);
		}
		negate = op == 7;
	}
	readtable(&t);
	if (!t.rows)
		return 1;
	col = column(&t, argv[1]);
	rows = ckmalloc(t.rows * sizeof(int));
	for (int r = 1; r < t.rows; r++) {
		const char *cell = cellat(&t, r, col);
		double v;
		int c, keep;

		if (op >= 6 && op <= 7) {
			keep = (regexec(&re, cell, 0, NULL, 0) == 0) != negate;
		} else if (op == 8) {
			keep = strstr(cell, value) != NULL;
		} else {
			c = wantnum && number(cell, &v) ? (v < want ? -1 : v > want) : strverscmp(cell, value);
			keep = (op == 0 && c == 0) || (op == 1 && c != 0) || (op == 2 && c < 0) ||
			       (op == 3 && c <= 0) || (op == 4 && c > 0) || (op == 5 && c >= 0);
		}
		if (keep)
			rows[n++] = r;
	}
	emit(&t, rows, n);
	return 0;
}

static struct table *sorting;
static int *sortcols;
static int nsortcols;
static int sortdesc;

static int bycolumns(const void *a, const void *b)
{
	int ra = *(const int *)a, rb = *(const int *)b;

	for (int i = 0; i < nsortcols; i++) {
		int c = compare(cellat(sorting, ra, sortcols[i]), cellat(sorting, rb, sortcols[i]));

		if (c)
			return sortdesc ? -c : c;
	}
	return ra - rb;
}

int sortbycmd(int argc, char **argv)
{
	struct table t;
	int *rows, i = 1;

	sortdesc = 0;
	if (argc > 1 && !strcmp(argv[1], "-r")) {
		sortdesc = 1;
		i++;
	}
	if (i >= argc)
		sh_error("usage: sort-by [-r] COLUMN...");
	readtable(&t);
	if (!t.rows)
		return 1;
	nsortcols = argc - i;
	sortcols = ckmalloc(nsortcols * sizeof(int));
	for (int k = 0; k < nsortcols; k++)
		sortcols[k] = column(&t, argv[i + k]);
	rows = ckmalloc(t.rows * sizeof(int));
	for (int r = 1; r < t.rows; r++)
		rows[r - 1] = r;
	sorting = &t;
	qsort(rows, t.rows - 1, sizeof(int), bycolumns);
	emit(&t, rows, t.rows - 1);
	return 0;
}

static int pickorreject(int argc, char **argv, int reject)
{
	struct table t, out = { 0 };
	int *keep, n = 0;
	char **fields;

	if (argc < 2)
		sh_error("usage: %s COLUMN...", argv[0]);
	readtable(&t);
	if (!t.rows)
		return 1;
	keep = ckmalloc((t.cols + argc) * sizeof(int));
	if (reject) {
		for (int c = 0; c < t.cols; c++) {
			int drop = 0;

			for (int i = 1; i < argc; i++)
				drop |= !strcmp(cellat(&t, 0, c), argv[i]);
			if (!drop)
				keep[n++] = c;
		}
	} else {
		for (int i = 1; i < argc; i++)
			keep[n++] = column(&t, argv[i]);
	}
	fields = ckmalloc((n + 1) * sizeof(char *));
	for (int r = 0; r < t.rows; r++) {
		for (int i = 0; i < n; i++)
			fields[i] = cellat(&t, r, keep[i]);
		addrow(&out, fields, n);
	}
	emitall(&out);
	return 0;
}

int pickcmd(int argc, char **argv)
{
	return pickorreject(argc, argv, 0);
}

int rejectcmd(int argc, char **argv)
{
	if (isatty(0))
		return external(argv);
	return pickorreject(argc, argv, 1);
}

static int firstorlast(int argc, char **argv, int last)
{
	struct table t;
	int want = argc > 1 ? atoi(argv[1]) : 1, n, from, *rows;

	if (want < 0)
		want = 0;
	readtable(&t);
	if (!t.rows)
		return 1;
	n = t.rows - 1 < want ? t.rows - 1 : want;
	from = last ? t.rows - n : 1;
	rows = ckmalloc((n + 1) * sizeof(int));
	for (int i = 0; i < n; i++)
		rows[i] = from + i;
	emit(&t, rows, n);
	return 0;
}

int firstcmd(int argc, char **argv)
{
	return firstorlast(argc, argv, 0);
}

int lastcmd(int argc, char **argv)
{
	if (isatty(0))
		return external(argv);
	return firstorlast(argc, argv, 1);
}

int countcmd(int argc, char **argv)
{
	struct table t;

	readtable(&t);
	out1fmt("%d\n", t.rows > 0 ? t.rows - 1 : 0);
	return 0;
}

/* ---------------------------------------------------------------- lsx and psx */

static void cleanfield(char *s)
{
	for (; *s; s++)
		if (*s == '\t' || *s == '\n')
			*s = ' ';
}

static const char *kind(mode_t m)
{
	return S_ISDIR(m) ? "dir" : S_ISLNK(m) ? "link" : S_ISREG(m) ? "file" : S_ISFIFO(m) ? "fifo" :
	       S_ISSOCK(m) ? "socket" : S_ISCHR(m) ? "char" : S_ISBLK(m) ? "block" : "?";
}

static void modestr(char *buf, mode_t m)
{
	const char *rwx = "rwxrwxrwx";

	for (int i = 0; i < 9; i++)
		buf[i] = m & (0400 >> i) ? rwx[i] : '-';
	buf[9] = 0;
}

static int bynames(const void *a, const void *b)
{
	return strverscmp(*(char *const *)a, *(char *const *)b);
}

static void lsdir(struct table *t, const char *dir, int all, int prefix)
{
	DIR *d = opendir(dir);
	struct dirent *e;
	char **names = NULL;
	int n = 0, cap = 0;

	if (!d) {
		sh_warnx("%s: %s", dir, strerror(errno));
		return;
	}
	while ((e = readdir(d))) {
		if (e->d_name[0] == '.' && (!all || !strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")))
			continue;
		if (n == cap)
			names = ckrealloc(names, (cap = cap * 2 + 32) * sizeof(char *));
		names[n++] = savestr(e->d_name);
	}
	closedir(d);
	qsort(names, n, sizeof(char *), bynames);
	for (int i = 0; i < n; i++) {
		struct stat st;
		char path[4096], size[32], when[32], mode[12];
		char *fields[5];

		snprintf(path, sizeof(path), "%s/%s", dir, names[i]);
		if (lstat(path, &st))
			continue;
		snprintf(size, sizeof(size), "%lld", (long long)st.st_size);
		strftime(when, sizeof(when), "%Y-%m-%d %H:%M", localtime(&st.st_mtime));
		modestr(mode, st.st_mode);
		fields[0] = savestr(prefix ? path : names[i]);
		cleanfield(fields[0]);
		fields[1] = (char *)kind(st.st_mode);
		fields[2] = savestr(size);
		fields[3] = savestr(when);
		fields[4] = savestr(mode);
		addrow(t, fields, 5);
	}
}

int lsxcmd(int argc, char **argv)
{
	struct table t = { 0 };
	char *head[] = { "name", "type", "size", "modified", "mode" };
	int all = 0, i = 1;

	if (argc > 1 && !strcmp(argv[1], "-a")) {
		all = 1;
		i++;
	}
	addrow(&t, head, 5);
	if (i >= argc)
		lsdir(&t, ".", all, 0);
	for (; i < argc; i++) {
		struct stat st;

		if (!stat(argv[i], &st) && S_ISDIR(st.st_mode)) {
			lsdir(&t, argv[i], all, argc - i > 1 || i > 1 + all);
		} else if (!lstat(argv[i], &st)) {
			char size[32], when[32], mode[12];
			char *fields[5];

			snprintf(size, sizeof(size), "%lld", (long long)st.st_size);
			strftime(when, sizeof(when), "%Y-%m-%d %H:%M", localtime(&st.st_mtime));
			modestr(mode, st.st_mode);
			fields[0] = argv[i];
			fields[1] = (char *)kind(st.st_mode);
			fields[2] = savestr(size);
			fields[3] = savestr(when);
			fields[4] = savestr(mode);
			addrow(&t, fields, 5);
		} else {
			sh_warnx("%s: %s", argv[i], strerror(errno));
		}
	}
	emitall(&t);
	return 0;
}

int psxcmd(int argc, char **argv)
{
	struct table t = { 0 };
	char *head[] = { "pid", "ppid", "name", "state", "threads", "mem", "user", "command" };
	DIR *d = opendir("/proc");
	struct dirent *e;
	long page = sysconf(_SC_PAGESIZE);

	if (!d)
		sh_error("/proc: %s", strerror(errno));
	addrow(&t, head, 8);
	while ((e = readdir(d))) {
		char path[64], stat[1024], cmd[4096], name[64], state[4], ppid[16], threads[16], mem[32], pid[16];
		char *fields[8], *open, *close;
		long long rss = 0;
		long nthreads = 0;
		int ppidv = 0;
		FILE *f;
		struct stat st;
		struct passwd *pw;
		size_t n;

		if (!isdigit((unsigned char)e->d_name[0]))
			continue;
		snprintf(path, sizeof(path), "/proc/%s/stat", e->d_name);
		if (!(f = fopen(path, "re")))
			continue;
		n = fread(stat, 1, sizeof(stat) - 1, f);
		fclose(f);
		stat[n] = 0;
		open = strchr(stat, '(');
		close = strrchr(stat, ')');
		if (!open || !close || close < open)
			continue;
		snprintf(name, sizeof(name), "%.*s", (int)(close - open - 1), open + 1);
		cleanfield(name);
		/* after the name: state ppid ... and the 20th field is the thread count */
		{
			char st1;
			int got = sscanf(close + 2, "%c %d %*d %*d %*d %*d %*u %*u %*u %*u %*u %*u %*u %*d %*d %*d %*d %ld %*d %*u %*u %lld",
					 &st1, &ppidv, &nthreads, &rss);

			if (got < 2)
				continue;
			state[0] = st1;
			state[1] = 0;
		}
		snprintf(path, sizeof(path), "/proc/%s/cmdline", e->d_name);
		cmd[0] = 0;
		if ((f = fopen(path, "re"))) {
			n = fread(cmd, 1, sizeof(cmd) - 1, f);
			fclose(f);
			for (size_t i = 0; i + 1 < n; i++)
				if (!cmd[i])
					cmd[i] = ' ';
			cmd[n] = 0;
		}
		cleanfield(cmd);
		snprintf(path, sizeof(path), "/proc/%s", e->d_name);
		pw = !lstat(path, &st) ? getpwuid(st.st_uid) : NULL;
		snprintf(pid, sizeof(pid), "%s", e->d_name);
		snprintf(ppid, sizeof(ppid), "%d", ppidv);
		snprintf(threads, sizeof(threads), "%ld", nthreads);
		snprintf(mem, sizeof(mem), "%lld", rss * page);
		fields[0] = savestr(pid);
		fields[1] = savestr(ppid);
		fields[2] = savestr(name);
		fields[3] = savestr(state);
		fields[4] = savestr(threads);
		fields[5] = savestr(mem);
		fields[6] = savestr(pw ? pw->pw_name : "?");
		fields[7] = savestr(*cmd ? cmd : name);
		addrow(&t, fields, 8);
	}
	closedir(d);
	emitall(&t);
	return 0;
}

/* ---------------------------------------------------------------- from and to */

struct text {
	char *p;
	size_t len, cap;
};

static void put(struct text *b, const char *s, size_t n)
{
	if (b->len + n + 1 > b->cap)
		b->p = ckrealloc(b->p, b->cap = (b->len + n + 1) * 2);
	memcpy(b->p + b->len, s, n);
	b->len += n;
	b->p[b->len] = 0;
}

static void putc_(struct text *b, char c)
{
	put(b, &c, 1);
}

/* A CSV field, quotes and all, as one tab-free cell. */
static void fromcsv(struct table *t, char *s)
{
	char **fields = NULL;
	int n = 0, cap = 0;
	struct text cell = { 0 };

	while (*s) {
		int quoted = *s == '"';

		cell.len = 0;
		put(&cell, "", 0);
		if (quoted) {
			s++;
			while (*s) {
				if (*s == '"' && s[1] == '"') {
					putc_(&cell, '"');
					s += 2;
				} else if (*s == '"') {
					s++;
					break;
				} else {
					putc_(&cell, *s == '\t' || *s == '\n' ? ' ' : *s);
					s++;
				}
			}
		}
		while (*s && *s != ',' && *s != '\n' && *s != '\r')
			putc_(&cell, *s == '\t' ? ' ' : *s), s++;
		if (n == cap)
			fields = ckrealloc(fields, (cap = cap * 2 + 8) * sizeof(char *));
		fields[n++] = savestr(cell.p);
		if (*s == ',') {
			s++;
			continue;
		}
		if (*s == '\r')
			s++;
		if (*s == '\n')
			s++;
		addrow(t, fields, n);
		n = 0;
	}
	if (n)
		addrow(t, fields, n);
}

/* ---- JSON, enough of it for tables */

static const char *js;

static void jspace(void)
{
	while (*js == ' ' || *js == '\t' || *js == '\n' || *js == '\r')
		js++;
}

static void jvalue(struct text *out);

static void jstring(struct text *out)
{
	js++;
	while (*js && *js != '"') {
		if (*js == '\\' && js[1]) {
			js++;
			switch (*js) {
			case 'n':
			case 't':
			case 'r':
				putc_(out, ' ');
				break;
			case 'u': {
				unsigned cp = 0;
				char utf[4];
				int k = 0;

				for (int i = 1; i <= 4 && js[i]; i++)
					cp = cp * 16 + (isdigit((unsigned char)js[i]) ? js[i] - '0' : (tolower((unsigned char)js[i]) - 'a' + 10));
				js += 4;
				if (cp < 0x80) {
					utf[k++] = cp < 0x20 ? ' ' : cp;
				} else if (cp < 0x800) {
					utf[k++] = 0xc0 | cp >> 6;
					utf[k++] = 0x80 | (cp & 0x3f);
				} else {
					utf[k++] = 0xe0 | cp >> 12;
					utf[k++] = 0x80 | ((cp >> 6) & 0x3f);
					utf[k++] = 0x80 | (cp & 0x3f);
				}
				put(out, utf, k);
				break;
			}
			default:
				putc_(out, *js);
			}
			js++;
			continue;
		}
		putc_(out, *js++);
	}
	if (*js == '"')
		js++;
}

/* A nested value as compact JSON text, for a cell. */
static void jraw(struct text *out)
{
	const char *start = js;
	int depth = 0, instr = 0;

	do {
		if (instr) {
			if (*js == '\\' && js[1])
				js++;
			else if (*js == '"')
				instr = 0;
		} else if (*js == '"') {
			instr = 1;
		} else if (*js == '{' || *js == '[') {
			depth++;
		} else if (*js == '}' || *js == ']') {
			depth--;
		}
		js++;
	} while (*js && depth > 0);
	for (const char *p = start; p < js; p++)
		if (*p != '\n' && *p != '\t' && *p != '\r')
			putc_(out, *p);
}

static void jvalue(struct text *out)
{
	jspace();
	if (*js == '"') {
		jstring(out);
	} else if (*js == '{' || *js == '[') {
		jraw(out);
	} else {
		while (*js && !strchr(",}] \t\n\r", *js))
			putc_(out, *js++);
	}
}

static void fromjson(struct table *t, const char *text)
{
	char **names = NULL, **row;
	int nnames = 0, cap = 0, nrows = 0, rowcap = 0;
	char ***rows = NULL;

	js = text;
	jspace();
	if (*js == '{') {
		/* one object: a row per key */
		char *head[] = { "key", "value" };

		addrow(t, head, 2);
		js++;
		for (;;) {
			struct text k = { 0 }, v = { 0 };
			char *fields[2];

			jspace();
			if (*js != '"')
				break;
			jstring(&k);
			jspace();
			if (*js == ':')
				js++;
			put(&v, "", 0);
			jvalue(&v);
			fields[0] = k.p;
			fields[1] = v.p;
			addrow(t, fields, 2);
			jspace();
			if (*js == ',')
				js++;
		}
		return;
	}
	if (*js != '[')
		sh_error("from json: a list of objects or one object is a table, this is neither");
	js++;
	for (;;) {
		jspace();
		if (*js == ']' || !*js)
			break;
		if (nrows == rowcap)
			rows = ckrealloc(rows, (rowcap = rowcap * 2 + 16) * sizeof(char **));
		row = NULL;
		if (*js == '{') {
			js++;
			row = ckmalloc(sizeof(char *) * 64);
			for (int i = 0; i < 64; i++)
				row[i] = NULL;
			for (;;) {
				struct text k = { 0 }, v = { 0 };
				int col;

				jspace();
				if (*js != '"')
					break;
				jstring(&k);
				jspace();
				if (*js == ':')
					js++;
				put(&v, "", 0);
				jvalue(&v);
				for (col = 0; col < nnames && strcmp(names[col], k.p); col++)
					;
				if (col == nnames && nnames < 64) {
					if (nnames == cap)
						names = ckrealloc(names, (cap = cap * 2 + 8) * sizeof(char *));
					names[nnames++] = k.p;
				}
				if (col < 64)
					row[col] = v.p;
				jspace();
				if (*js == ',')
					js++;
			}
			jspace();
			if (*js == '}')
				js++;
		} else {
			struct text v = { 0 };

			put(&v, "", 0);
			jvalue(&v);
			row = ckmalloc(sizeof(char *) * 64);
			for (int i = 0; i < 64; i++)
				row[i] = NULL;
			row[0] = v.p;
			if (!nnames) {
				names = ckrealloc(names, sizeof(char *) * 8);
				names[0] = "value";
				nnames = cap = 1;
			}
		}
		rows[nrows++] = row;
		jspace();
		if (*js == ',')
			js++;
	}
	addrow(t, names, nnames);
	for (int r = 0; r < nrows; r++) {
		for (int c = 0; c < nnames; c++)
			if (!rows[r][c])
				rows[r][c] = "";
		addrow(t, rows[r], nnames);
	}
}

int fromcmd(int argc, char **argv)
{
	struct table t = { 0 };
	char *text;

	if (isatty(0))
		return external(argv);
	if (argc != 2)
		sh_error("usage: from csv|json|ssv|tsv");
	text = readall(0);
	if (!strcmp(argv[1], "csv"))
		fromcsv(&t, text);
	else if (!strcmp(argv[1], "json"))
		fromjson(&t, text);
	else if (!strcmp(argv[1], "ssv") || !strcmp(argv[1], "tsv"))
		parse(&t, text);
	else
		sh_error("from: %s: csv, json, ssv or tsv", argv[1]);
	emitall(&t);
	return 0;
}

static void jsonstr(const char *s)
{
	out1c('"');
	for (; *s; s++) {
		if (*s == '"' || *s == '\\')
			out1fmt("\\%c", *s);
		else if ((unsigned char)*s < 0x20)
			out1fmt("\\u%04x", *s);
		else
			out1c(*s);
	}
	out1c('"');
}

int tocmd(int argc, char **argv)
{
	struct table t;

	if (argc != 2 || (strcmp(argv[1], "csv") && strcmp(argv[1], "json") && strcmp(argv[1], "tsv")))
		sh_error("usage: to csv|json|tsv");
	readtable(&t);
	if (!strcmp(argv[1], "tsv")) {
		writetsv(&t, 0, t.rows);
	} else if (!strcmp(argv[1], "csv")) {
		for (int r = 0; r < t.rows; r++) {
			for (int c = 0; c < t.cols; c++) {
				const char *cell = cellat(&t, r, c);

				if (strpbrk(cell, ",\"\n")) {
					out1c('"');
					for (; *cell; cell++) {
						if (*cell == '"')
							out1c('"');
						out1c(*cell);
					}
					out1c('"');
				} else {
					out1str(cell);
				}
				out1c(c == t.cols - 1 ? '\n' : ',');
			}
		}
	} else {
		out1str("[");
		for (int r = 1; r < t.rows; r++) {
			out1str(r > 1 ? ",\n  {" : "\n  {");
			for (int c = 0; c < t.cols; c++) {
				const char *cell = cellat(&t, r, c);
				double v;

				if (c)
					out1str(", ");
				jsonstr(cellat(&t, 0, c));
				out1str(": ");
				if (number(cell, &v) && strspn(cell, "0123456789.-+eE") == strlen(cell))
					out1str(cell);
				else if (!strcmp(cell, "true") || !strcmp(cell, "false") || !strcmp(cell, "null"))
					out1str(cell);
				else
					jsonstr(cell);
			}
			out1c('}');
		}
		out1str(t.rows > 1 ? "\n]\n" : "]\n");
	}
	return 0;
}
