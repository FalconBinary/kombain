/* The hooks fdash adds to dash; see fdash.c. SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef FDASH_H
#define FDASH_H

int fdash_active(void);
int fdash_read(char *buf, int n);

/* var.c owns the variable table. */
void fdash_setstatus(int status);

/* exec.c and alias.c own their tables, so the listings live there. */
int fdash_isfunction(const char *name);
void fdash_listfunctions(void (*fn)(const char *, void *), void *arg);
void fdash_listaliases(void (*fn)(const char *, void *), void *arg);

#endif
