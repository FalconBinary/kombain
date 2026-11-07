/* Helpers shared by the fdash sources. SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef FDASH_UTIL_H
#define FDASH_UTIL_H

#include <stddef.h>
#include <sys/types.h>

#ifndef FDASH_DATADIR
#define FDASH_DATADIR "/usr/local/share/fdash"
#endif

/* A growing string, always NUL-terminated once anything was added. */
struct sb {
	char *s;
	size_t len, cap;
};

void sb_add(struct sb *b, const char *s, size_t n);
void sb_str(struct sb *b, const char *s);
void sb_chr(struct sb *b, char c);
void sb_clear(struct sb *b);
void sb_markup(struct sb *b, const char *s);
void sb_quote(struct sb *b, const char *s);

int control_len(const char *s);
int is_dir(const char *path);
int open_regular(const char *path, off_t *size);
char *read_text(const char *path, size_t limit);

/* ~/.config/fdash, ~/.local/share/fdash and ~/.cache/fdash, honoring XDG_*_HOME. 0 without a home. */
int config_dir(struct sb *out);
int data_dir(struct sb *out);
int cache_dir(struct sb *out);
int mkdirs(const char *path);

int read_first_line(const char *path, char *buf, size_t size);
int run_capture(char *const argv[], char *const envp[], int timeout_ms, struct sb *out, size_t limit);

/* Candidate generators (gen.c). The callback returns 0 to stop; help may be NULL. */
typedef int gen_fn(const char *word, size_t len, const char *help, void *arg);

int gen_run(const char *name, int hinting, gen_fn *fn, void *arg);
int git_dir(const char *cwd, struct sb *dir);

/* Directory history (commands.c), newest first. */
void dirh_each(gen_fn *fn, void *arg);

#endif
