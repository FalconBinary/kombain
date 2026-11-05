/* ----------------------------------------------------------------------------
  Copyright (c) 2021, Daan Leijen
  This is free software; you can redistribute it and/or modify it
  under the terms of the MIT License. A copy of the license can be
  found in the "LICENSE" file at the root of this distribution.
-----------------------------------------------------------------------------*/
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

#include "../include/isocline.h"
#include "common.h"
#include "history.h"
#include "stringbuf.h"

#define IC_MAX_HISTORY (100000)

struct history_s {
  ssize_t  count;              // current number of entries in use
  ssize_t  len;                // size of elems
  const char** elems;         // history items (up to count)
  const char*  fname;         // history file
  alloc_t* mem;
  bool     allow_duplicates;   // allow duplicate entries?
  off_t    read_off;           // fdash: how much of the history file has been read
};

ic_private history_t* history_new(alloc_t* mem) {
  history_t* h = mem_zalloc_tp(mem,history_t);
  h->mem = mem;
  return h;
}

ic_private void history_free(history_t* h) {
  if (h == NULL) return;
  history_clear(h);
  if (h->len > 0) {
    mem_free( h->mem, h->elems );
    h->elems = NULL;
    h->len = 0;
  }
  mem_free(h->mem, h->fname);
  h->fname = NULL;
  mem_free(h->mem, h); // free ourselves
}

ic_private bool history_enable_duplicates( history_t* h, bool enable ) {
  bool prev = h->allow_duplicates;
  h->allow_duplicates = enable;
  return prev;
}

ic_private ssize_t  history_count(const history_t* h) {
  return h->count;
}

//-------------------------------------------------------------
// push/clear
//-------------------------------------------------------------

ic_private bool history_update( history_t* h, const char* entry ) {
  if (entry==NULL) return false;
  history_remove_last(h);
  history_push(h,entry);
  //debug_msg("history: update: with %s; now at %s\n", entry, history_get(h,0));
  return true;
}

static void history_delete_at( history_t* h, ssize_t idx ) {
  if (idx < 0 || idx >= h->count) return;
  mem_free(h->mem, h->elems[idx]);
  for(ssize_t i = idx+1; i < h->count; i++) {
    h->elems[i-1] = h->elems[i];
  }
  h->count--;
}

ic_private bool history_push( history_t* h, const char* entry ) {
  if (h->len <= 0 || entry==NULL)  return false;
  // remove any older duplicate
  if (!h->allow_duplicates) {
    for( int i = 0; i < h->count; i++) {
      if (strcmp(h->elems[i],entry) == 0) {
        history_delete_at(h,i);
      }
    }
  }
  // insert at front
  if (h->count == h->len) {
    // delete oldest entry
    history_delete_at(h,0);
  }
  assert(h->count < h->len);
  h->elems[h->count] = mem_strdup(h->mem,entry);
  h->count++;
  return true;
}


static void history_remove_last_n( history_t* h, ssize_t n ) {
  if (n <= 0) return;
  if (n > h->count) n = h->count;
  for( ssize_t i = h->count - n; i < h->count; i++) {
    mem_free( h->mem, h->elems[i] );
  }
  h->count -= n;
  assert(h->count >= 0);
}

ic_private void history_remove_last(history_t* h) {
  history_remove_last_n(h,1);
}

ic_private void history_clear(history_t* h) {
  history_remove_last_n( h, h->count );
}

ic_private const char* history_get( const history_t* h, ssize_t n ) {
  if (n < 0 || n >= h->count) return NULL;
  return h->elems[h->count - n - 1];
}

ic_private bool history_search( const history_t* h, ssize_t from /*including*/, const char* search, bool backward, ssize_t* hidx, ssize_t* hpos ) {
  const char* p = NULL;
  ssize_t i;
  if (backward) {
    for( i = from; i < h->count; i++ ) {
      p = strstr( history_get(h,i), search);
      if (p != NULL) break;
    }
  }
  else {
    for( i = from; i >= 0; i-- ) {
      p = strstr( history_get(h,i), search);
      if (p != NULL) break;
    }
  }
  if (p == NULL) return false;
  if (hidx != NULL) *hidx = i;
  if (hpos != NULL) *hpos = (p - history_get(h,i));
  return true;
}

//-------------------------------------------------------------
//
//-------------------------------------------------------------

ic_private void history_load_from(history_t* h, const char* fname, long max_entries ) {
  history_clear(h);
  h->fname = mem_strdup(h->mem,fname);
  if (max_entries == 0) {
    assert(h->elems == NULL);
    return;
  }
  if (max_entries < 0 || max_entries > IC_MAX_HISTORY) max_entries = IC_MAX_HISTORY;
  h->elems = (const char**)mem_zalloc_tp_n(h->mem, char*, max_entries );
  if (h->elems == NULL) return;
  h->len = max_entries;
  history_load(h);
}




//-------------------------------------------------------------
// save/load history to file
//-------------------------------------------------------------

static char from_xdigit( int c ) {
  if (c >= '0' && c <= '9') return (char)(c - '0');
  if (c >= 'A' && c <= 'F') return (char)(10 + (c - 'A'));
  if (c >= 'a' && c <= 'f') return (char)(10 + (c - 'a'));
  return 0;
}

static char to_xdigit( uint8_t c ) {
  if (c <= 9) return ((char)c + '0');
  if (c >= 10 && c <= 15) return ((char)c - 10 + 'A');
  return '0';
}

static bool ic_isxdigit( int c ) {
  return ((c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') || (c >= '0' && c <= '9'));
}

// fdash: decodes one line of the history file
static bool history_decode_entry( const char* s, stringbuf_t* sbuf ) {
  sbuf_clear(sbuf);
  while (*s != 0) {
    int c = (uint8_t)*s++;
    if (c == '\\') {
      c = (uint8_t)*s;
      if (c != 0) s++;
      if (c == 'n')       { sbuf_append(sbuf,"\n"); }
      else if (c == 'r')  { /* ignore */ }
      else if (c == 't')  { sbuf_append(sbuf,"\t"); }
      else if (c == '\\') { sbuf_append(sbuf,"\\"); }
      else if (c == 'x') {
        int c1 = (uint8_t)s[0];
        int c2 = (c1 != 0 ? (uint8_t)s[1] : 0);
        if (ic_isxdigit(c1) && ic_isxdigit(c2)) {
          s += 2;
          sbuf_append_char(sbuf, from_xdigit(c1)*16 + from_xdigit(c2));
        }
        else return false;
      }
      else return false;
    }
    else if (c != '\r') {
      sbuf_append_char(sbuf,(char)c);
    }
  }
  return true;
}

static bool history_write_entry( const char* entry, FILE* f, stringbuf_t* sbuf ) {
  sbuf_clear(sbuf);
  //debug_msg("history: write: %s\n", entry);
  while( entry != NULL && *entry != 0 ) {
    char c = *entry++;
    if (c == '\\')      { sbuf_append(sbuf,"\\\\"); }
    else if (c == '\n') { sbuf_append(sbuf,"\\n"); }
    else if (c == '\r') { /* ignore */ } // sbuf_append(sbuf,"\\r"); }
    else if (c == '\t') { sbuf_append(sbuf,"\\t"); }
    else if (c < ' ' || c > '~' || c == '#') {
      char c1 = to_xdigit( (uint8_t)c / 16 );
      char c2 = to_xdigit( (uint8_t)c % 16 );
      sbuf_append(sbuf,"\\x");
      sbuf_append_char(sbuf,c1);
      sbuf_append_char(sbuf,c2);
    }
    else sbuf_append_char(sbuf,c);
  }
  //debug_msg("history: write buf: %s\n", sbuf_string(sbuf));

  if (sbuf_len(sbuf) > 0) {
    sbuf_append(sbuf,"\n");
    fputs(sbuf_string(sbuf),f);
  }
  return true;
}

// fdash: reads `size` bytes from `off`; the buffer ends in a 0 and must be freed by the caller
static char* history_read_file( history_t* h, off_t off, off_t* size ) {
  int fd = open(h->fname, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return NULL;
  struct stat st;
  char* buf = NULL;
  if (fstat(fd,&st) == 0 && st.st_size >= off && lseek(fd,off,SEEK_SET) == off) {
    size_t want = (size_t)(st.st_size - off);
    buf = (char*)mem_malloc(h->mem, (ssize_t)want + 1);
    if (buf != NULL) {
      size_t got = 0;
      while (got < want) {
        ssize_t n = read(fd, buf + got, want - got);
        if (n <= 0) break;
        got += (size_t)n;
      }
      buf[got] = 0;
      *size = off + (off_t)got;
    }
  }
  close(fd);
  return buf;
}

static uint32_t history_hash( const char* s ) {
  uint32_t x = 2166136261u;
  for (; *s != 0; s++) { x = (x ^ (uint8_t)*s) * 16777619u; }
  return x;
}

// fdash: walks the file newest first with a hash set of seen lines, so a large history loads in O(n)
ic_private void history_load( history_t* h ) {
  if (h->fname == NULL || h->len <= 0) return;
  off_t size = 0;
  char* buf = history_read_file(h, 0, &size);
  if (buf == NULL) return;
  h->read_off = size;
  ssize_t nlines = 0;
  for (char* p = buf; *p != 0; p++) { if (*p == '\n') nlines++; }
  nlines++;
  char** lines = (char**)mem_malloc(h->mem, nlines * (ssize_t)sizeof(char*));
  ssize_t nslots = 2*nlines + 1;
  int32_t* slots = (int32_t*)mem_zalloc(h->mem, nslots * (ssize_t)sizeof(int32_t));
  stringbuf_t* sbuf = sbuf_new(h->mem);
  if (lines != NULL && slots != NULL && sbuf != NULL) {
    ssize_t n = 0;
    for (char* p = buf; p != NULL && *p != 0; ) {
      lines[n++] = p;
      p = strchr(p,'\n');
      if (p != NULL) { *p++ = 0; }
    }
    ssize_t kept = 0;
    for (ssize_t i = n-1; i >= 0 && kept < h->len; i--) {
      if (lines[i][0] == 0 || lines[i][0] == '#') continue;
      ssize_t slot = (ssize_t)(history_hash(lines[i]) % (uint32_t)nslots);
      bool dup = false;
      while (slots[slot] != 0) {
        if (strcmp(lines[slots[slot]-1], lines[i]) == 0) { dup = true; break; }
        slot = (slot + 1) % nslots;
      }
      if (dup) continue;
      slots[slot] = (int32_t)(i+1);
      if (history_decode_entry(lines[i],sbuf) && sbuf_len(sbuf) > 0) {
        h->elems[h->len - ++kept] = mem_strdup(h->mem, sbuf_string(sbuf));
      }
    }
    if (kept < h->len) { memmove(h->elems, h->elems + (h->len - kept), (size_t)kept * sizeof(char*)); }
    h->count = kept;
    // the file only ever grows between loads: drop old and duplicate lines once it doubled
    if (n > 2*kept + 64) { history_save(h); }
  }
  sbuf_free(sbuf);
  mem_free(h->mem, slots);
  mem_free(h->mem, lines);
  mem_free(h->mem, buf);
}

// fdash: rewrites the file atomically
ic_private void history_save( history_t* h ) {
  if (h->fname == NULL) return;
  stringbuf_t* tmp = sbuf_new(h->mem);
  stringbuf_t* sbuf = sbuf_new(h->mem);
  if (tmp != NULL && sbuf != NULL) {
    char pid[32];
    snprintf(pid, sizeof(pid), ".%ld.tmp", (long)getpid());
    sbuf_replace(tmp, h->fname);
    sbuf_append(tmp, pid);
    int fd = open(sbuf_string(tmp), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, S_IRUSR|S_IWUSR);
    FILE* f = (fd >= 0 ? fdopen(fd,"w") : NULL);
    if (f != NULL) {
      for (ssize_t i = 0; i < h->count; i++) {
        if (!history_write_entry(h->elems[i],f,sbuf)) break;
      }
      bool ok = (fflush(f) == 0);
      off_t end = ftello(f);
      fclose(f);
      if (ok && rename(sbuf_string(tmp), h->fname) == 0) { h->read_off = end; }
      else { unlink(sbuf_string(tmp)); }
    }
  }
  sbuf_free(sbuf);
  sbuf_free(tmp);
}

// fdash: appends the newest entry; one O_APPEND write keeps lines of concurrent shells intact
ic_private void history_append_last( history_t* h ) {
  if (h->fname == NULL || h->count <= 0) return;
  int fd = open(h->fname, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, S_IRUSR|S_IWUSR);
  if (fd < 0) return;
  FILE* f = fdopen(fd,"a");
  stringbuf_t* sbuf = sbuf_new(h->mem);
  if (f != NULL && sbuf != NULL) { history_write_entry(h->elems[h->count-1],f,sbuf); }
  sbuf_free(sbuf);
  if (f != NULL) { fclose(f); } else { close(fd); }
}

// fdash: picks up what other running shells appended since the last look
ic_private void history_sync( history_t* h ) {
  if (h->fname == NULL || h->len <= 0) return;
  struct stat st;
  if (stat(h->fname,&st) != 0 || st.st_size == h->read_off) return;
  if (st.st_size < h->read_off) {
    history_clear(h);
    h->read_off = 0;
    history_load(h);
    return;
  }
  off_t size = h->read_off;
  char* buf = history_read_file(h, h->read_off, &size);
  if (buf == NULL) return;
  stringbuf_t* sbuf = sbuf_new(h->mem);
  if (sbuf != NULL) {
    char* p = buf;
    char* nl;
    while ((nl = strchr(p,'\n')) != NULL) {
      *nl = 0;
      if (p[0] != 0 && p[0] != '#' && history_decode_entry(p,sbuf) && sbuf_len(sbuf) > 0) {
        history_push(h, sbuf_string(sbuf));
      }
      p = nl + 1;
    }
    h->read_off += (off_t)(p - buf);   // a partial last line is read again next time
    sbuf_free(sbuf);
  }
  mem_free(h->mem, buf);
}
