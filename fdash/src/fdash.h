/* The hooks fdash adds to dash; see fdash.c. SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef FDASH_H
#define FDASH_H

int fdash_active(void);
int fdash_read(char *buf, int n);
int fdash_line_saved(void);

/* var.c owns the variable table. */
void fdash_setstatus(int status);
int fdash_setvar(const char *name, const char *val, int export);

/* commands.c */
void fdash_startup(void);
int fdash_autoload(const char *name);
int fdash_autoload_exists(const char *name);
void fdash_listautoload(void (*fn)(const char *, void *), void *arg);
int fdash_not_found(int argc, char **argv);
void fdash_defun(const void *node, const char *name, int linno);

/* The parser records a function definition as it reads it (input.c, parser.c). */
extern void *fdash_rec_file;
void fdash_rec_start(void *file);
void fdash_rec_stop(const void *node, const char *name, int linno, int pushback);
void fdash_rec_char(int c);
void fdash_rec_unget(int n);
void fdash_rec_mark(void);
void fdash_rec_reset(void);
void fdash_dirh_update(void);
void fdash_uvars_check(void);

/* exec.c and alias.c own their tables, so the listings live there. */
int fdash_isfunction(const char *name);
void fdash_listfunctions(void (*fn)(const char *, void *), void *arg);
void fdash_listaliases(void (*fn)(const char *, void *), void *arg);

#endif
