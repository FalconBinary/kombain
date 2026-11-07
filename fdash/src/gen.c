/*
 * Candidate generators: the lists a completion spec names with @name.
 *
 * The cheap ones are built in and read files directly: users, hosts, runit
 * services, processes, git refs. git itself never runs, so completing in a
 * hostile repository runs nothing from it.
 *
 * Any other name is a program in ~/.config/fdash/generators or
 * $DATADIR/generators that prints "word<TAB>description" lines. When its
 * first line is "#cache PATH...", the output is kept in ~/.cache/fdash until
 * one of those paths changes, and "#cache 300s" keeps it for five minutes.
 * Suggestions only read a fresh cache: a key press never starts a program.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <ctype.h>
#include <dirent.h>
#include <grp.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "shell.h"
#include "memalloc.h"
#include "var.h"

#include "util.h"

#define GEN_TIMEOUT_MS 5000
#define GEN_OUTPUT_MAX (16 << 20)

/* ------------------------------------------------------------ text lines */

/* Calls fn for each "word<TAB>help" line of text; skips comments. */
static int each_line(const char *text, gen_fn *fn, void *arg)
{
	static struct sb help;

	while (*text) {
		const char *eol = strchr(text, '\n');
		size_t n = eol ? (size_t)(eol - text) : strlen(text);
		const char *tab = memchr(text, '\t', n);

		if (n && *text != '#') {
			size_t wlen = tab ? (size_t)(tab - text) : n;

			sb_clear(&help);
			if (tab)
				sb_add(&help, tab + 1, n - wlen - 1);
			if (wlen && !fn(text, wlen, tab ? help.s : NULL, arg))
				return 0;
		}
		text += n + (eol ? 1 : 0);
	}
	return 1;
}

/* --------------------------------------------------------------- accounts */

static int gen_users(int hinting, gen_fn *fn, void *arg)
{
	struct passwd *pw;
	int go = 1;

	(void)hinting;
	setpwent();
	while (go && (pw = getpwent())) {
		char gecos[64];

		snprintf(gecos, sizeof(gecos), "%s", pw->pw_gecos ? pw->pw_gecos : "");
		gecos[strcspn(gecos, ",")] = 0;
		go = fn(pw->pw_name, strlen(pw->pw_name), *gecos ? gecos : NULL, arg);
	}
	endpwent();
	return 1;
}

static int gen_groups(int hinting, gen_fn *fn, void *arg)
{
	struct group *gr;
	int go = 1;

	(void)hinting;
	setgrent();
	while (go && (gr = getgrent()))
		go = fn(gr->gr_name, strlen(gr->gr_name), NULL, arg);
	endgrent();
	return 1;
}

/* ------------------------------------------------------------------ hosts */

static int host_ok(const char *h, size_t n)
{
	size_t i;

	if (!n || *h == '|' || *h == '-')
		return 0;
	for (i = 0; i < n; i++)
		if (strchr("*?!/", h[i]) || control_len(h + i))
			return 0;
	return 1;
}

/* Hosts from ~/.ssh/config, known_hosts and /etc/hosts. */
static int gen_hosts(int hinting, gen_fn *fn, void *arg)
{
	static const char *const known[] = { "/.ssh/known_hosts", "/etc/ssh/ssh_known_hosts" };
	const char *home = lookupvar("HOME");
	struct sb path = {0};
	char *text;
	size_t k;
	int go = 1;

	(void)hinting;
	if (home) {
		sb_str(&path, home);
		sb_str(&path, "/.ssh/config");
		if ((text = read_text(path.s, 1 << 20))) {
			char *line = text, *next;

			for (; go && line; line = next) {
				char *p = line, *w;

				if ((next = strchr(line, '\n')))
					*next++ = 0;
				while (*p == ' ' || *p == '\t')
					p++;
				if (strncasecmp(p, "host", 4) || !(p[4] == ' ' || p[4] == '\t' || p[4] == '='))
					continue;
				for (p += 5; go && (w = strtok(p, " \t=")); p = NULL)
					if (host_ok(w, strlen(w)))
						go = fn(w, strlen(w), "Host from ~/.ssh/config", arg);
			}
			free(text);
		}
	}
	for (k = 0; go && k < sizeof(known) / sizeof(known[0]); k++) {
		char *line, *next;

		sb_clear(&path);
		if (k == 0) {
			if (!home)
				continue;
			sb_str(&path, home);
		}
		sb_str(&path, known[k]);
		if (!(text = read_text(path.s, 8 << 20)))
			continue;
		for (line = text; go && line; line = next) {
			char *h, *end;

			if ((next = strchr(line, '\n')))
				*next++ = 0;
			if (*line == '@') {	/* @cert-authority and @revoked: the hosts come second */
				line += strcspn(line, " \t");
				line += strspn(line, " \t");
			}
			end = line + strcspn(line, " \t");
			*end = 0;
			for (h = line; go && h < end; h += strcspn(h, ",") + 1) {
				size_t n = strcspn(h, ",");

				if (*h == '[' && memchr(h, ']', n)) {
					n = (size_t)((char *)memchr(h, ']', n) - h) - 1;
					h++;
				}
				if (host_ok(h, n))
					go = fn(h, n, "Known host", arg);
			}
		}
		free(text);
	}
	if (go && (text = read_text("/etc/hosts", 1 << 20))) {
		char *line, *next;

		for (line = text; go && line; line = next) {
			char *w, *p = line;

			if ((next = strchr(line, '\n')))
				*next++ = 0;
			line[strcspn(line, "#")] = 0;
			if (!(w = strtok(p, " \t")))
				continue;
			while (go && (w = strtok(NULL, " \t")))
				if (host_ok(w, strlen(w)))
					go = fn(w, strlen(w), "/etc/hosts", arg);
		}
		free(text);
	}
	free(path.s);
	return 1;
}

/* --------------------------------------------------------------- services */

/* runit services in $SVDIR, /var/service by default, with their state. */
static int gen_services(int hinting, gen_fn *fn, void *arg)
{
	const char *dir = lookupvar("SVDIR");
	struct sb path = {0};
	struct dirent *e;
	DIR *d;
	int go = 1;

	if (!dir || !*dir)
		dir = "/var/service";
	if (!(d = opendir(dir)))
		return 1;
	while (go && (e = readdir(d))) {
		char state[32];
		const char *help = "Service";

		if (e->d_name[0] == '.')
			continue;
		sb_clear(&path);
		sb_str(&path, dir);
		sb_chr(&path, '/');
		sb_str(&path, e->d_name);
		if (!is_dir(path.s))
			continue;
		sb_str(&path, "/supervise/stat");
		if (!hinting && read_first_line(path.s, state, sizeof(state)))
			help = !strcmp(state, "run") ? "Service, running" : !strcmp(state, "down") ? "Service, down" : "Service";
		go = fn(e->d_name, strlen(e->d_name), help, arg);
	}
	closedir(d);
	free(path.s);
	return 1;
}

/* -------------------------------------------------------------- processes */

static int is_number(const char *s)
{
	if (!*s)
		return 0;
	while (isdigit((unsigned char)*s))
		s++;
	return !*s;
}

static int cmp_str(const void *a, const void *b)
{
	return strcmp(*(char *const *)a, *(char *const *)b);
}

static void proc_name(const char *pid, char *buf, size_t size)
{
	char path[64];

	snprintf(path, sizeof(path), "/proc/%s/comm", pid);
	if (!read_first_line(path, buf, size))
		*buf = 0;
}

/* Names of running processes, for pkill and killall; a key press does not read /proc. */
static int gen_processes(int hinting, gen_fn *fn, void *arg)
{
	char **names = NULL;
	size_t n = 0, cap = 0, i;
	struct dirent *e;
	DIR *d;
	int go = 1;

	if (hinting || !(d = opendir("/proc")))
		return 1;
	while ((e = readdir(d))) {
		char name[64];

		if (!is_number(e->d_name))
			continue;
		proc_name(e->d_name, name, sizeof(name));
		if (!*name)
			continue;
		if (n == cap) {
			char **nn = realloc(names, (cap = cap ? cap * 2 : 256) * sizeof(*names));

			if (!nn)
				break;
			names = nn;
		}
		if ((names[n] = strdup(name)))
			n++;
	}
	closedir(d);
	if (n)
		qsort(names, n, sizeof(*names), cmp_str);
	for (i = 0; i < n; i++) {
		if (go && (i == 0 || strcmp(names[i], names[i - 1])))
			go = fn(names[i], strlen(names[i]), "Process", arg);
	}
	for (i = 0; i < n; i++)
		free(names[i]);
	free(names);
	return 1;
}

/* Process IDs with their names, the user's own unless root: what kill may signal. */
static int gen_pids(int hinting, gen_fn *fn, void *arg)
{
	struct sb path = {0};
	struct dirent *e;
	DIR *d;
	uid_t me = geteuid();
	pid_t self = getpid();
	int go = 1;

	if (hinting || !(d = opendir("/proc")))
		return 1;
	while (go && (e = readdir(d))) {
		struct stat st;
		char name[64];

		if (!is_number(e->d_name) || atol(e->d_name) == (long)self)
			continue;
		sb_clear(&path);
		sb_str(&path, "/proc/");
		sb_str(&path, e->d_name);
		if (stat(path.s, &st) || (me && st.st_uid != me))
			continue;
		proc_name(e->d_name, name, sizeof(name));
		if (*name)
			go = fn(e->d_name, strlen(e->d_name), name, arg);
	}
	closedir(d);
	free(path.s);
	return 1;
}

static int gen_signals(int hinting, gen_fn *fn, void *arg)
{
	static const char *const sigs[] = {
		"HUP\tHang up", "INT\tInterrupt", "QUIT\tQuit with a core dump", "KILL\tKill, cannot be caught",
		"TERM\tTerminate", "USR1\tUser signal 1", "USR2\tUser signal 2", "STOP\tStop, cannot be caught",
		"CONT\tContinue", "TSTP\tStop from the terminal", "WINCH\tWindow size changed", "ALRM\tAlarm",
	};
	size_t i;

	(void)hinting;
	for (i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++)
		if (!each_line(sigs[i], fn, arg))
			break;
	return 1;
}

/* -------------------------------------------------------------------- git */

/* The repository's git directory for cwd: the one that holds refs (commondir for a worktree). */
int git_dir(const char *cwd, struct sb *out)
{
	struct sb dir = {0}, path = {0};
	char line[4096];
	int found = 0;

	sb_str(&dir, cwd);
	for (;;) {
		struct stat st;
		char *slash;

		sb_clear(&path);
		sb_str(&path, dir.s);
		sb_str(&path, "/.git");
		if (stat(path.s, &st) == 0) {
			if (read_first_line(path.s, line, sizeof(line)) && !strncmp(line, "gitdir: ", 8)) {
				sb_clear(&path);
				if (line[8] != '/') {
					sb_str(&path, dir.s);
					sb_chr(&path, '/');
				}
				sb_str(&path, line + 8);
			}
			sb_clear(out);
			sb_str(out, path.s);
			sb_str(&path, "/commondir");
			if (read_first_line(path.s, line, sizeof(line))) {
				if (line[0] != '/')
					sb_chr(out, '/');
				else
					sb_clear(out);
				sb_str(out, line);
			}
			found = 1;
			break;
		}
		slash = strrchr(dir.s, '/');
		if (!slash || slash == dir.s)
			break;
		*slash = 0;
		dir.len = (size_t)(slash - dir.s);
	}
	free(dir.s);
	free(path.s);
	return found;
}

struct refwalk {
	gen_fn *fn;
	void *arg;
	const char *help;
	int go;
};

static int ref_ok(const char *name, size_t n)
{
	size_t i;

	for (i = 0; i < n; i++)
		if (control_len(name + i))
			return 0;
	return n && !(n >= 4 && !strcmp(name + n - 4, "HEAD"));
}

/* Every ref file under dir, named relative to the walk's start. */
static void walk_refs(struct refwalk *w, struct sb *dir, size_t base, int depth)
{
	struct dirent *e;
	DIR *d;
	size_t keep = dir->len;

	if (depth > 8 || !(d = opendir(dir->s)))
		return;
	while (w->go && (e = readdir(d))) {
		struct stat st;

		if (e->d_name[0] == '.')
			continue;
		dir->len = keep;
		sb_chr(dir, '/');
		sb_str(dir, e->d_name);
		if (lstat(dir->s, &st))
			continue;
		if (S_ISDIR(st.st_mode))
			walk_refs(w, dir, base, depth + 1);
		else if (S_ISREG(st.st_mode) && ref_ok(dir->s + base, dir->len - base))
			w->go = w->fn(dir->s + base, dir->len - base, w->help, w->arg);
	}
	dir->len = keep;
	dir->s[keep] = 0;
	closedir(d);
}

/* Loose refs under refs/<kind>, then packed ones. */
static void git_refs(const char *kind, const char *help, gen_fn *fn, void *arg)
{
	struct refwalk w = { fn, arg, help, 1 };
	struct sb dir = {0}, prefix = {0};
	const char *cwd = lookupvar("PWD");
	char *text;
	size_t base;

	if (!cwd || !git_dir(cwd, &dir))
		goto out;
	sb_str(&prefix, "refs/");
	sb_str(&prefix, kind);
	sb_chr(&prefix, '/');
	{
		size_t root = dir.len;

		sb_chr(&dir, '/');
		sb_str(&dir, prefix.s);
		dir.s[--dir.len] = 0;	/* no trailing slash */
		base = dir.len + 1;
		walk_refs(&w, &dir, base, 0);
		dir.len = root;
		dir.s[root] = 0;
	}
	sb_str(&dir, "/packed-refs");
	if (w.go && (text = read_text(dir.s, 32 << 20))) {
		char *line, *next;

		for (line = text; w.go && line; line = next) {
			char *ref;

			if ((next = strchr(line, '\n')))
				*next++ = 0;
			if (*line == '#' || *line == '^' || !(ref = strchr(line, ' ')))
				continue;
			ref++;
			if (!strncmp(ref, prefix.s, prefix.len) && ref_ok(ref + prefix.len, strlen(ref + prefix.len)))
				w.go = fn(ref + prefix.len, strlen(ref + prefix.len), help, arg);
		}
		free(text);
	}
out:
	free(dir.s);
	free(prefix.s);
}

static int gen_git_branches(int hinting, gen_fn *fn, void *arg)
{
	(void)hinting;
	git_refs("heads", "Branch", fn, arg);
	git_refs("remotes", "Remote branch", fn, arg);
	return 1;
}

static int gen_git_tags(int hinting, gen_fn *fn, void *arg)
{
	(void)hinting;
	git_refs("tags", "Tag", fn, arg);
	return 1;
}

/* Remotes from [remote "name"] sections of the repository's config. */
static int gen_git_remotes(int hinting, gen_fn *fn, void *arg)
{
	struct sb dir = {0};
	const char *cwd = lookupvar("PWD");
	char *text, *line, *next;
	int go = 1;

	(void)hinting;
	if (cwd && git_dir(cwd, &dir)) {
		sb_str(&dir, "/config");
		if ((text = read_text(dir.s, 1 << 20))) {
			for (line = text; go && line; line = next) {
				char *q;

				if ((next = strchr(line, '\n')))
					*next++ = 0;
				while (*line == ' ' || *line == '\t')
					line++;
				if (strncmp(line, "[remote \"", 9) || !(q = strchr(line + 9, '"')))
					continue;
				if (ref_ok(line + 9, (size_t)(q - line - 9)))
					go = fn(line + 9, (size_t)(q - line - 9), "Remote", arg);
			}
			free(text);
		}
	}
	free(dir.s);
	return 1;
}

static int gen_dirh(int hinting, gen_fn *fn, void *arg)
{
	(void)hinting;
	dirh_each(fn, arg);
	return 1;
}

/* ------------------------------------------------------ program generators */

/* What fdash keeps of one program generator's output. */
struct gcache {
	char *name;
	char *text;
	struct timespec mtime;
	off_t size;
	ino_t ino;
	struct gcache *next;
};

static struct gcache *gcaches;

static int newer(const struct timespec *a, const struct timespec *b)
{
	return a->tv_sec > b->tv_sec || (a->tv_sec == b->tv_sec && a->tv_nsec > b->tv_nsec);
}

/* Is the output still good? Its first line says what it was made from. */
static int cache_fresh(const char *text, const struct stat *made)
{
	const char *p = text + 6, *end = strchr(text, '\n');
	struct sb path = {0};
	int fresh = 1;

	if (strncmp(text, "#cache", 6) || !end)
		return 0;
	while (fresh && p < end) {
		size_t n;
		struct stat st;

		while (p < end && (*p == ' ' || *p == '\t'))
			p++;
		n = strcspn(p, " \t\n");
		if (!n)
			break;
		if (isdigit((unsigned char)*p) && p[n - 1] == 's') {
			fresh = time(NULL) - made->st_mtime < atol(p);
		} else if (*p == '/') {
			sb_clear(&path);
			sb_add(&path, p, n);
			fresh = stat(path.s, &st) == 0 && !newer(&st.st_mtim, &made->st_mtim);
		}
		p += n;
	}
	free(path.s);
	return fresh;
}

static int name_ok(const char *name)
{
	const char *p;

	if (!*name || *name == '.' || strlen(name) > 64)
		return 0;
	for (p = name; *p; p++)
		if (!(isalnum((unsigned char)*p) || strchr("._-+", *p)))
			return 0;
	return 1;
}

static int find_program(const char *name, struct sb *path)
{
	struct stat st;

	if (config_dir(path)) {
		sb_str(path, "/generators/");
		sb_str(path, name);
		if (stat(path->s, &st) == 0 && S_ISREG(st.st_mode) && access(path->s, X_OK) == 0)
			return 1;
	}
	sb_clear(path);
	sb_str(path, FDASH_DATADIR "/generators/");
	sb_str(path, name);
	return stat(path->s, &st) == 0 && S_ISREG(st.st_mode) && access(path->s, X_OK) == 0;
}

/* Runs the program; keeps its output in the cache when it says how long it stays good. */
static char *run_program(const char *prog, const char *cache)
{
	struct stackmark mark;
	struct sb out = {0};
	char *argv[] = { (char *)prog, NULL };
	char **env;
	int status;

	setstackmark(&mark);
	env = listvars(VEXPORT, VUNSET, NULL);
	status = run_capture(argv, env, GEN_TIMEOUT_MS, &out, GEN_OUTPUT_MAX);
	popstackmark(&mark);
	if (status != 0) {
		free(out.s);
		return NULL;
	}
	sb_add(&out, "", 0);
	if (cache && !strncmp(out.s, "#cache", 6)) {
		struct sb tmp = {0};
		char pid[32];
		FILE *f;

		sb_str(&tmp, cache);
		snprintf(pid, sizeof(pid), ".%ld", (long)getpid());
		sb_str(&tmp, pid);
		if ((f = fopen(tmp.s, "w"))) {
			int ok = fwrite(out.s, 1, out.len, f) == out.len;

			if (fclose(f) == 0 && ok)
				rename(tmp.s, cache);
			else
				unlink(tmp.s);
		}
		free(tmp.s);
	}
	return out.s;
}

static int gen_program(const char *name, int hinting, gen_fn *fn, void *arg)
{
	struct sb prog = {0}, cache = {0};
	struct gcache *g;
	struct stat st;
	char *text = NULL;
	int have_cache = cache_dir(&cache);

	if (!find_program(name, &prog)) {
		free(prog.s);
		free(cache.s);
		return 0;
	}
	if (have_cache) {
		sb_chr(&cache, '/');
		sb_str(&cache, name);
	}
	for (g = gcaches; g && strcmp(g->name, name); g = g->next)
		;
	if (have_cache && stat(cache.s, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == geteuid()) {
		/* another shell may have refreshed it */
		if (!g || g->ino != st.st_ino || g->size != st.st_size || newer(&st.st_mtim, &g->mtime)
		    || newer(&g->mtime, &st.st_mtim)) {
			if (!g && (g = calloc(1, sizeof(*g)))) {
				g->name = strdup(name);
				g->next = gcaches;
				gcaches = g;
			}
			if (g) {
				free(g->text);
				g->text = read_text(cache.s, GEN_OUTPUT_MAX + 1);
				g->mtime = st.st_mtim;
				g->size = st.st_size;
				g->ino = st.st_ino;
			}
		}
		if (g && g->text && cache_fresh(g->text, &st))
			text = g->text;
	}
	if (text) {
		each_line(strchr(text, '\n') + 1, fn, arg);
	} else if (!hinting) {
		if (have_cache) {
			char *slash = strrchr(cache.s, '/');

			*slash = 0;
			mkdirs(cache.s);
			*slash = '/';
		}
		if ((text = run_program(prog.s, have_cache ? cache.s : NULL))) {
			each_line(text, fn, arg);
			free(text);
		}
	}
	free(prog.s);
	free(cache.s);
	return 1;
}

/* ------------------------------------------------------------------ table */

static const struct {
	const char *name;
	int (*run)(int hinting, gen_fn *fn, void *arg);
} builtin_gens[] = {
	{ "dirh", gen_dirh },
	{ "git-branches", gen_git_branches },
	{ "git-remotes", gen_git_remotes },
	{ "git-tags", gen_git_tags },
	{ "groups", gen_groups },
	{ "hosts", gen_hosts },
	{ "pids", gen_pids },
	{ "processes", gen_processes },
	{ "services", gen_services },
	{ "signals", gen_signals },
	{ "users", gen_users },
};

/* Feeds the candidates of generator name to fn. Returns 0 if there is no such generator. */
int gen_run(const char *name, int hinting, gen_fn *fn, void *arg)
{
	size_t i;

	for (i = 0; i < sizeof(builtin_gens) / sizeof(builtin_gens[0]); i++)
		if (!strcmp(builtin_gens[i].name, name))
			return builtin_gens[i].run(hinting, fn, arg);
	return name_ok(name) && gen_program(name, hinting, fn, arg);
}
