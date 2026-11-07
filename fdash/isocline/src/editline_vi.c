/* ----------------------------------------------------------------------------
  fdash: vi editing, for `set -o vi`. This file is included in editline.c.

  Escape leaves insert mode for command mode, where the keys of vi's
  command line work: motions (h l w b e W B E 0 ^ $, with counts), the
  operators d c y with a motion or doubled, x X D C s S r ~ p P, the ways
  back into insert mode (i a I A), u to undo, k and j through the history,
  / to search it, v edits the line in $EDITOR as Alt+E does. Enter runs
  the line from either mode. The cursor is a block in command mode. Alt and
  a letter count as escape and that letter: a quick typist's escape.

  Under the MIT License, as the rest of isocline (see LICENSE).
-----------------------------------------------------------------------------*/

static char* vi_yank;   // what d, c, x and y took last

static int vi_class(char c) {
  if (c == ' ' || c == '\t' || c == '\n') return 0;
  if ((unsigned char)c >= 0x80 || c == '_' || (c >= '0' && c <= '9') || ((c | 0x20) >= 'a' && (c | 0x20) <= 'z')) return 1;
  return 2;
}

static int vi_wclass(char c, bool big) {
  int k = vi_class(c);
  return (big && k == 2 ? 1 : k);
}

// the start of the next word (w, W)
static ssize_t vi_next_word(const char* s, ssize_t len, ssize_t pos, bool big) {
  if (pos >= len) return len;
  int k = vi_wclass(s[pos], big);
  while (pos < len && k != 0 && vi_wclass(s[pos], big) == k) pos++;
  while (pos < len && vi_class(s[pos]) == 0) pos++;
  return pos;
}

// the start of this or the previous word (b, B)
static ssize_t vi_prev_word(const char* s, ssize_t pos, bool big) {
  while (pos > 0 && vi_class(s[pos-1]) == 0) pos--;
  if (pos == 0) return 0;
  int k = vi_wclass(s[pos-1], big);
  while (pos > 0 && vi_wclass(s[pos-1], big) == k) pos--;
  return pos;
}

// just past the end of this or the next word (e, E)
static ssize_t vi_word_end(const char* s, ssize_t len, ssize_t pos, bool big) {
  if (pos < len) pos++;
  while (pos < len && vi_class(s[pos]) == 0) pos++;
  if (pos >= len) return len;
  int k = vi_wclass(s[pos], big);
  while (pos < len && vi_wclass(s[pos], big) == k) pos++;
  return pos;
}

// the start of the character before end
static ssize_t vi_char_before(editor_t* eb, ssize_t end) {
  ssize_t prev = sbuf_prev(eb->input, end, NULL);
  return (prev < 0 ? 0 : prev);
}

// in command mode the cursor stays on a character
static void vi_clamp(editor_t* eb) {
  ssize_t len = sbuf_len(eb->input);
  if (len > 0 && eb->pos >= len) eb->pos = vi_char_before(eb, len);
}

static void vi_set_cursor(ic_env_t* env, bool block) {
  term_write(env->term, block ? "\x1b[2 q" : "\x1b[0 q");
}

static void vi_enter_command(ic_env_t* env, editor_t* eb) {
  eb->vi_cmd = true;
  ssize_t start = sbuf_find_line_start(eb->input, eb->pos);
  if (eb->pos > 0 && eb->pos > start) eb->pos = vi_char_before(eb, eb->pos);
  vi_clamp(eb);
  vi_set_cursor(env, true);
  edit_refresh(env, eb);
}

static void vi_enter_insert(ic_env_t* env, editor_t* eb) {
  eb->vi_cmd = false;
  vi_set_cursor(env, false);
  edit_refresh(env, eb);
}

// where a motion takes the cursor, or -1; *inclusive for motions that end on a character
static ssize_t vi_motion(editor_t* eb, code_t c, long count, bool* inclusive) {
  const char* s = sbuf_string(eb->input);
  ssize_t len = sbuf_len(eb->input);
  ssize_t pos = eb->pos;
  *inclusive = false;
  if (count < 1) count = 1;
  switch (c) {
    case 'h': case KEY_LEFT: case KEY_BACKSP:
      while (count-- > 0 && pos > 0) pos = vi_char_before(eb, pos);
      return pos;
    case 'l': case KEY_RIGHT: case ' ':
      while (count-- > 0 && pos < len) { ssize_t n = sbuf_next(eb->input, pos, NULL); pos = (n < 0 ? len : n); }
      return pos;
    case '0': case KEY_HOME: return 0;
    case '^': { ssize_t k = (ssize_t)strspn(s, " \t"); return (k < len ? k : 0); }
    case '$': case KEY_END: *inclusive = true; return (len > 0 ? vi_char_before(eb, len) : 0);
    case 'w': case 'W':
      while (count-- > 0) pos = vi_next_word(s, len, pos, c == 'W');
      return pos;
    case 'b': case 'B':
      while (count-- > 0) pos = vi_prev_word(s, pos, c == 'B');
      return pos;
    case 'e': case 'E':
      while (count-- > 0) pos = vi_word_end(s, len, pos, c == 'E');
      *inclusive = true;
      return (pos > 0 ? vi_char_before(eb, pos) : 0);
    default:
      return -1;
  }
}

static void vi_take(ic_env_t* env, ssize_t from, ssize_t to, stringbuf_t* sb) {
  mem_free(env->mem, vi_yank);
  vi_yank = mem_strndup(env->mem, sbuf_string(sb) + from, to - from);
}

// a command-mode key; false for keys the editor handles as usual (enter, ctrl keys, tab)
static bool edit_vi_command(ic_env_t* env, editor_t* eb, code_t c) {
  static long count = 0;
  static code_t op = 0;      // d, c or y waiting for its motion
  static long opcount = 0;
  ssize_t len = sbuf_len(eb->input);
  bool inclusive;

  if (c >= '1' && c <= '9') { count = count * 10 + (long)(c - '0'); return true; }
  if (c == '0' && count > 0) { count *= 10; return true; }
  long n = (count > 0 ? count : 1);
  count = 0;

  if (op != 0) {
    code_t o = op;
    op = 0;
    n *= (opcount > 0 ? opcount : 1);
    ssize_t from, to;
    if (c == o) {   // dd, cc, yy: the whole line
      from = 0;
      to = len;
    }
    else {
      // cw changes to the end of the word, as in vi
      code_t m = (o == 'c' && (c == 'w' || c == 'W') && eb->pos < len && vi_class(sbuf_string(eb->input)[eb->pos]) != 0 ? (c == 'w' ? 'e' : 'E') : c);
      ssize_t target = vi_motion(eb, m, n, &inclusive);
      if (target < 0) { term_beep(env->term); return true; }
      if (inclusive && target < len) { ssize_t nx = sbuf_next(eb->input, target, NULL); target = (nx < 0 ? len : nx); }
      from = (target < eb->pos ? target : eb->pos);
      to = (target < eb->pos ? eb->pos : target);
    }
    vi_take(env, from, to, eb->input);
    if (o != 'y') {
      editor_start_modify(eb);
      sbuf_delete_from_to(eb->input, from, to);
    }
    eb->pos = from;
    if (o == 'c') { vi_enter_insert(env, eb); return true; }
    vi_clamp(eb);
    edit_refresh(env, eb);
    return true;
  }

  ssize_t target = vi_motion(eb, c, n, &inclusive);
  if (target >= 0) {
    eb->pos = target;
    vi_clamp(eb);
    edit_refresh(env, eb);
    return true;
  }
  switch (c) {
    case 'd': case 'c': case 'y':
      op = c;
      opcount = n;
      return true;
    case 'i': case KEY_INS:
      vi_enter_insert(env, eb);
      return true;
    case 'a':
      if (eb->pos < len) { ssize_t nx = sbuf_next(eb->input, eb->pos, NULL); eb->pos = (nx < 0 ? len : nx); }
      vi_enter_insert(env, eb);
      return true;
    case 'I':
      eb->pos = (ssize_t)strspn(sbuf_string(eb->input), " \t");
      vi_enter_insert(env, eb);
      return true;
    case 'A':
      eb->pos = len;
      vi_enter_insert(env, eb);
      return true;
    case 'x': case KEY_DEL: case 'X': case 's': {
      ssize_t from = eb->pos, to = eb->pos;
      if (c == 'X') { while (n-- > 0 && from > 0) from = vi_char_before(eb, from); }
      else { while (n-- > 0 && to < len) { ssize_t nx = sbuf_next(eb->input, to, NULL); to = (nx < 0 ? len : nx); } }
      if (from == to && c != 's') return true;
      vi_take(env, from, to, eb->input);
      editor_start_modify(eb);
      sbuf_delete_from_to(eb->input, from, to);
      eb->pos = from;
      if (c == 's') { vi_enter_insert(env, eb); return true; }
      vi_clamp(eb);
      edit_refresh(env, eb);
      return true;
    }
    case 'D': case 'C':
      vi_take(env, eb->pos, len, eb->input);
      editor_start_modify(eb);
      sbuf_delete_from(eb->input, eb->pos);
      if (c == 'C') { vi_enter_insert(env, eb); return true; }
      vi_clamp(eb);
      edit_refresh(env, eb);
      return true;
    case 'S':
      vi_take(env, 0, len, eb->input);
      editor_start_modify(eb);
      sbuf_clear(eb->input);
      eb->pos = 0;
      vi_enter_insert(env, eb);
      return true;
    case 'p': case 'P':
      if (vi_yank == NULL || *vi_yank == 0) return true;
      editor_start_modify(eb);
      if (c == 'p' && eb->pos < len) { ssize_t nx = sbuf_next(eb->input, eb->pos, NULL); eb->pos = (nx < 0 ? len : nx); }
      while (n-- > 0) eb->pos = sbuf_insert_at(eb->input, vi_yank, eb->pos);
      eb->pos = vi_char_before(eb, eb->pos);
      vi_clamp(eb);
      edit_refresh(env, eb);
      return true;
    case 'r': {
      code_t r = tty_read(env->tty);
      char ch;
      if (eb->pos >= len || !code_is_ascii_char(r, &ch)) return true;
      editor_start_modify(eb);
      sbuf_delete_char_at(eb->input, eb->pos);
      sbuf_insert_char_at(eb->input, ch, eb->pos);
      edit_refresh(env, eb);
      return true;
    }
    case '~':
      if (eb->pos >= len) return true;
      editor_start_modify(eb);
      while (n-- > 0 && eb->pos < len) {
        char ch = sbuf_char_at(eb->input, eb->pos);
        if (ch >= 'a' && ch <= 'z') ch = (char)(ch - 32);
        else if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + 32);
        sbuf_delete_char_at(eb->input, eb->pos);
        sbuf_insert_char_at(eb->input, ch, eb->pos);
        ssize_t nx = sbuf_next(eb->input, eb->pos, NULL);
        eb->pos = (nx < 0 ? len : nx);
      }
      vi_clamp(eb);
      edit_refresh(env, eb);
      return true;
    case 'u':
      edit_undo_restore(env, eb);
      vi_clamp(eb);
      edit_refresh(env, eb);
      return true;
    case KEY_CTRL_R:
      edit_redo_restore(env, eb);
      vi_clamp(eb);
      edit_refresh(env, eb);
      return true;
    case 'k': case '-': case KEY_UP:
      edit_history_prev(env, eb);
      vi_clamp(eb);
      edit_refresh(env, eb);
      return true;
    case 'j': case '+': case KEY_DOWN:
      edit_history_next(env, eb);
      vi_clamp(eb);
      edit_refresh(env, eb);
      return true;
    case '/': case '?':
      edit_history_search(env, eb, (char*)"");
      return true;
    case KEY_ESC:
      return true;
    default: {
      char ch;
      if (code_is_ascii_char(c, &ch)) { term_beep(env->term); return true; }  // no such command
      return false;
    }
  }
}
