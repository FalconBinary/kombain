/*
 * Strings, files and child processes for the rest of fdash.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "shell.h"
#include "var.h"

#include "util.h"

/* ---------------------------------------------------------------- strings */

void sb_add(struct sb *b, const char *s, size_t n)
{
	if (b->len + n + 1 > b->cap) {
		size_t cap = b->cap ? b->cap * 2 : 128;
		char *p;

		while (cap < b->len + n + 1)
			cap *= 2;
		p = realloc(b->s, cap);
		if (!p) {
			static const char msg[] = "fdash: out of memory\n";

			if (write(2, msg, sizeof(msg) - 1) < 0)
				_exit(2);
			_exit(2);
		}
		b->s = p;
		b->cap = cap;
	}
	memcpy(b->s + b->len, s, n);
	b->len += n;
	b->s[b->len] = 0;
}

void sb_str(struct sb *b, const char *s)
{
	sb_add(b, s, strlen(s));
}

void sb_chr(struct sb *b, char c)
{
	sb_add(b, &c, 1);
}

void sb_clear(struct sb *b)
{
	b->len = 0;
	sb_add(b, "", 0);
}

/* Length of a C0, DEL or UTF-8 encoded C1 control at s, which a terminal would act on. */
int control_len(const char *s)
{
	unsigned char c = (unsigned char)s[0];

	if (c < 0x20 || c == 0x7f)
		return 1;
	if (c == 0xc2 && (unsigned char)s[1] >= 0x80 && (unsigned char)s[1] <= 0x9f)
		return 2;
	return 0;
}

/*
 * Text for the prompt or a menu: isocline reads these as markup. It may come
 * from a file name or a repository, so it can never reach the terminal as a
 * control sequence.
 */
void sb_markup(struct sb *b, const char *s)
{
	while (*s) {
		int ctl = control_len(s);

		if (ctl) {
			sb_chr(b, '?');
			s += ctl;
			continue;
		}
		if (*s == '[' || *s == '\\')
			sb_chr(b, '\\');
		sb_chr(b, *s++);
	}
}

/* s as one shell word in single quotes, for lines fdash hands to the shell. */
void sb_quote(struct sb *b, const char *s)
{
	sb_chr(b, '\'');
	for (; *s; s++) {
		if (*s == '\'')
			sb_str(b, "'\\''");
		else
			sb_chr(b, *s);
	}
	sb_chr(b, '\'');
}

/* ------------------------------------------------------------------ files */

int is_dir(const char *path)
{
	struct stat st;

	return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

/*
 * Opens a regular file. A name in a directory someone else made can be a FIFO or
 * a link to the terminal, and opening or reading those would hang the prompt.
 */
int open_regular(const char *path, off_t *size)
{
	struct stat st;
	int fd = open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC);

	if (fd < 0)
		return -1;
	if (fstat(fd, &st) || !S_ISREG(st.st_mode)) {
		close(fd);
		return -1;
	}
	if (size)
		*size = st.st_size;
	return fd;
}

/* The whole of a regular file smaller than limit, NUL-terminated, or NULL. */
char *read_text(const char *path, size_t limit)
{
	off_t size = 0;
	int fd = open_regular(path, &size);
	char *buf = NULL;

	if (fd < 0)
		return NULL;
	if ((size_t)size < limit && (buf = malloc((size_t)size + 1))) {
		size_t got = 0;
		ssize_t n;

		while (got < (size_t)size && (n = read(fd, buf + got, (size_t)size - got)) > 0)
			got += (size_t)n;
		buf[got] = 0;
	}
	close(fd);
	return buf;
}

/* The first line of a small regular file, without its newline. */
int read_first_line(const char *path, char *buf, size_t size)
{
	int fd = open_regular(path, NULL);
	ssize_t n;

	if (fd < 0)
		return 0;
	n = read(fd, buf, size - 1);
	close(fd);
	if (n <= 0)
		return 0;
	buf[n] = 0;
	buf[strcspn(buf, "\n")] = 0;
	return 1;
}

static int xdg_dir(struct sb *out, const char *var, const char *fallback)
{
	const char *dir = lookupvar(var);

	sb_clear(out);
	if (dir && *dir == '/') {
		sb_str(out, dir);
	} else if ((dir = lookupvar("HOME")) && *dir) {
		sb_str(out, dir);
		sb_str(out, fallback);
	} else {
		return 0;
	}
	sb_str(out, "/fdash");
	return 1;
}

int config_dir(struct sb *out)
{
	return xdg_dir(out, "XDG_CONFIG_HOME", "/.config");
}

int data_dir(struct sb *out)
{
	return xdg_dir(out, "XDG_DATA_HOME", "/.local/share");
}

int cache_dir(struct sb *out)
{
	return xdg_dir(out, "XDG_CACHE_HOME", "/.cache");
}

/* mkdir -p, private: what fdash keeps there is nobody else's business. */
int mkdirs(const char *path)
{
	struct sb dir = {0};
	char *p;
	int ok;

	sb_str(&dir, path);
	for (p = dir.s + 1; (p = strchr(p, '/')); p++) {
		*p = 0;
		mkdir(dir.s, 0700);
		*p = '/';
	}
	ok = mkdir(dir.s, 0700) == 0 || errno == EEXIST;
	free(dir.s);
	return ok && is_dir(path);
}

/* ------------------------------------------------------- child processes */

static long now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/*
 * Runs argv[0] (a path) with stdin from /dev/null and no stderr, in a process
 * group of its own so a pipeline in it can be stopped as a whole. Up to limit
 * bytes of its output go to out. Gives up after timeout_ms: a completion must
 * never hang the prompt. Returns the exit status, or -1.
 */
int run_capture(char *const argv[], char *const envp[], int timeout_ms, struct sb *out, size_t limit)
{
	static const int reset[] = { SIGINT, SIGQUIT, SIGTERM, SIGTSTP, SIGTTIN, SIGTTOU, SIGPIPE, SIGCHLD };
	long deadline = now_ms() + timeout_ms;
	int fds[2], status = -1, done = 0;
	pid_t pid;

	if (pipe(fds))
		return -1;
	fcntl(fds[0], F_SETFD, FD_CLOEXEC);
	pid = fork();
	if (pid < 0) {
		close(fds[0]);
		close(fds[1]);
		return -1;
	}
	if (pid == 0) {
		sigset_t none;
		int null = open("/dev/null", O_RDWR);
		size_t i;

		setpgid(0, 0);
		for (i = 0; i < sizeof(reset) / sizeof(reset[0]); i++)
			signal(reset[i], SIG_DFL);
		sigemptyset(&none);
		sigprocmask(SIG_SETMASK, &none, NULL);
		if (null < 0 || dup2(null, 0) < 0 || dup2(fds[1], 1) < 0 || dup2(null, 2) < 0)
			_exit(127);
		if (envp)
			execve(argv[0], argv, envp);
		else
			execv(argv[0], argv);
		_exit(127);
	}
	setpgid(pid, pid);
	close(fds[1]);
	while (!done) {
		struct pollfd p = { fds[0], POLLIN, 0 };
		long left = deadline - now_ms();
		char buf[4096];
		ssize_t n;

		if (left <= 0)
			break;
		if (poll(&p, 1, (int)left) < 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		if (!p.revents)
			continue;
		n = read(fds[0], buf, sizeof(buf));
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			done = 1;
		else if (out->len + (size_t)n <= limit)
			sb_add(out, buf, (size_t)n);
		else
			break;
	}
	if (!done) {
		kill(-pid, SIGKILL);
		kill(pid, SIGKILL);
	}
	close(fds[0]);
	while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
		;
	if (!done)
		return -1;
	return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}
