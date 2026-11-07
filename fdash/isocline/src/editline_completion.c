/* ----------------------------------------------------------------------------
  Copyright (c) 2021, Daan Leijen
  This is free software; you can redistribute it and/or modify it
  under the terms of the MIT License. A copy of the license can be
  found in the "LICENSE" file at the root of this distribution.
-----------------------------------------------------------------------------*/

//-------------------------------------------------------------
// Completion menu: this file is included in editline.c
//-------------------------------------------------------------

// return true iff the buffer or cursor position was actually changed;
// clean up any dirtiness in the undo stack. update eb->pos if appropriate
static bool edit_completion_commit(editor_t* eb, ssize_t newpos) {
  if (newpos == IC_COMP_APPLY_FAIL) {
    editor_undo_restore(eb, false);
    return false;
  }
  if (newpos == IC_COMP_APPLY_NOOP) {
    editor_undo_forget(eb);
    return false;
  }

  eb->pos = newpos;
  return true;
}

// return true if anything changed
static bool edit_complete(ic_env_t* env, editor_t* eb, ssize_t idx) {
  editor_start_modify(eb);
  ssize_t newpos = completions_apply(env->completions, idx, eb->input, eb->pos);
  bool buf_or_pos_changed = edit_completion_commit(eb, newpos);

  // trigger a refresh if the buffer or cursor position changed
  if (buf_or_pos_changed)
    edit_refresh(env, eb);
  // or when choosing between menu items, even if the current item is the same
  // as the buffer, because we need to highlight that item
  else if (newpos == IC_COMP_APPLY_NOOP && completions_count(env->completions) > 1)
    edit_refresh(env, eb);

  return buf_or_pos_changed;
}

static void edit_complete_longest_prefix(ic_env_t* env, editor_t* eb ) {
  editor_start_modify(eb);
  ssize_t newpos = completions_apply_longest_prefix( env->completions, eb->input, eb->pos );
  edit_completion_commit(eb, newpos);
}

ic_private void sbuf_append_tagged( stringbuf_t* sb, const char* tag, const char* content ) {
  sbuf_appendf(sb, "[%s]", tag);  
  sbuf_append(sb,content);
  sbuf_append(sb,"[/]");
}

//-------------------------------------------------------------
// fdash: a pager as in fish. Candidates and their descriptions in columns,
// filled top to bottom; tab and the arrows select (the line shows the
// selection), typing narrows the list, enter takes the selection.
//-------------------------------------------------------------

#define IC_PAGER_GAP        2
#define IC_PAGER_DESC_MAX   40
#define IC_PAGER_FOLDED     8

typedef struct pager_s {
  ssize_t  count;
  ssize_t  rows, cols;
  ssize_t* colw;        // width of each column
  ssize_t  first;       // first row shown
  ssize_t  shown;       // rows shown
  ssize_t  selected;    // -1: none yet
  bool     expanded;    // after the first selection the pager may use the whole screen
} pager_t;

static ssize_t pager_cell_width(ic_env_t* env, ssize_t idx) {
  const char* help = NULL;
  const char* display = completions_get_display(env->completions, idx, &help);
  ssize_t w = bbcode_column_width(env->bbcode, display);
  if (help != NULL) {
    ssize_t hw = bbcode_column_width(env->bbcode, help);
    w += IC_PAGER_GAP + 2 + (hw > IC_PAGER_DESC_MAX ? IC_PAGER_DESC_MAX : hw);
  }
  return w;
}

static ssize_t edit_input_rows(ic_env_t* env, editor_t* eb) {
  ssize_t promptw, cpromptw;
  rowcol_t rc;
  edit_get_prompt_width(env, eb, false, &promptw, &cpromptw);
  return sbuf_get_rc_at_pos(eb->input, eb->termw, promptw, cpromptw, sbuf_len(eb->input), &rc);
}

// as many columns as fit, like fish; descriptions are cut first
static void pager_layout(ic_env_t* env, editor_t* eb, pager_t* pg) {
  const ssize_t termw = term_get_width(env->term) - 1;
  ssize_t* w = mem_malloc_tp_n(env->mem, ssize_t, pg->count);
  mem_free(env->mem, pg->colw);
  pg->colw = mem_zalloc_tp_n(env->mem, ssize_t, pg->count);
  if (w == NULL || pg->colw == NULL) { mem_free(env->mem, w); pg->rows = pg->count; pg->cols = 1; return; }
  ssize_t minw = termw;
  for (ssize_t i = 0; i < pg->count; i++) {
    w[i] = pager_cell_width(env, i);
    if (w[i] < minw) minw = w[i];
  }
  ssize_t cols = termw / (minw + IC_PAGER_GAP);
  if (cols > pg->count) cols = pg->count;
  if (cols < 1) cols = 1;
  for (; cols >= 1; cols--) {
    ssize_t rows = (pg->count + cols - 1) / cols;
    ssize_t used = (pg->count + rows - 1) / rows;   // columns that hold anything
    ssize_t total = IC_PAGER_GAP * (used - 1);
    for (ssize_t c = 0; c < used; c++) {
      ssize_t m = 0;
      for (ssize_t r = 0; r < rows && c * rows + r < pg->count; r++) {
        if (w[c * rows + r] > m) m = w[c * rows + r];
      }
      pg->colw[c] = m;
      total += m;
    }
    if (total <= termw || cols == 1) {
      pg->rows = rows;
      pg->cols = used;
      if (cols == 1 && pg->colw[0] > termw) pg->colw[0] = termw;
      break;
    }
  }
  mem_free(env->mem, w);
  // how many rows fit below the input
  ssize_t avail = term_get_height(env->term) - edit_input_rows(env, eb) - 1;
  if (avail < 1) avail = 1;
  if (!pg->expanded && avail > IC_PAGER_FOLDED) avail = IC_PAGER_FOLDED;
  pg->shown = (pg->rows < avail ? pg->rows : avail);
  if (pg->selected >= 0) {
    ssize_t row = pg->selected % pg->rows;
    if (row < pg->first) pg->first = row;
    if (row >= pg->first + pg->shown) pg->first = row - pg->shown + 1;
  }
  if (pg->first + pg->shown > pg->rows) pg->first = pg->rows - pg->shown;
  if (pg->first < 0) pg->first = 0;
}

static void pager_render(ic_env_t* env, editor_t* eb, pager_t* pg, bool more_available) {
  sbuf_clear(eb->extra);
  for (ssize_t r = pg->first; r < pg->first + pg->shown; r++) {
    if (r > pg->first) sbuf_append(eb->extra, "\n");
    for (ssize_t c = 0; c < pg->cols; c++) {
      ssize_t idx = c * pg->rows + r;
      if (idx >= pg->count) break;
      const char* help = NULL;
      const char* display = completions_get_display(env->completions, idx, &help);
      if (c > 0) sbuf_append(eb->extra, "  ");
      if (idx == pg->selected) sbuf_append(eb->extra, "[reverse]");
      sbuf_appendf(eb->extra, "[width=\"%zd;left; ;on\"]", pg->colw[c]);
      sbuf_append(eb->extra, display);
      if (help != NULL) {
        sbuf_append(eb->extra, "  [ic-info](");
        sbuf_append(eb->extra, help);
        sbuf_append(eb->extra, ")[/ic-info]");
      }
      sbuf_append(eb->extra, "[/width]");
      if (idx == pg->selected) sbuf_append(eb->extra, "[/reverse]");
    }
  }
  ssize_t hidden = pg->rows - pg->shown;
  if (hidden > 0 && pg->selected < 0) {
    sbuf_appendf(eb->extra, "\n[ic-info]\xE2\x80\xA6" "and %zd more rows%s[/]", hidden, (more_available ? " (and more not shown)" : ""));
  }
  else if (hidden > 0) {
    sbuf_appendf(eb->extra, "\n[ic-info]rows %zd to %zd of %zd[/]", pg->first + 1, pg->first + pg->shown, pg->rows);
  }
  else if (more_available) {
    sbuf_append(eb->extra, "\n[ic-info](more not shown: type to narrow)[/]");
  }
}

static void pager_close(ic_env_t* env, editor_t* eb, pager_t* pg) {
  mem_free(env->mem, pg->colw);
  pg->colw = NULL;
  sbuf_clear(eb->extra);
  completions_clear(env->completions);
  edit_refresh(env, eb);
}

static void pager_move(pager_t* pg, code_t c) {
  ssize_t sel = pg->selected;
  ssize_t n = pg->count;
  if (sel < 0) {
    sel = (c == KEY_UP || c == KEY_SHIFT_TAB || c == KEY_LEFT ? n - 1 : 0);
  }
  else if (c == KEY_TAB || c == KEY_DOWN) {
    sel = (sel + 1) % n;
  }
  else if (c == KEY_SHIFT_TAB || c == KEY_UP) {
    sel = (sel + n - 1) % n;
  }
  else if (c == KEY_RIGHT) {
    sel = (sel + pg->rows < n ? sel + pg->rows : (sel % pg->rows + 1) % pg->rows);
    if (sel >= n) sel = 0;
  }
  else if (c == KEY_LEFT) {
    if (sel - pg->rows >= 0) sel -= pg->rows;
    else {
      ssize_t row = (sel % pg->rows + pg->rows - 1) % pg->rows;
      sel = (pg->cols - 1) * pg->rows + row;
      while (sel >= n) sel -= pg->rows;
    }
  }
  else if (c == KEY_PAGEDOWN) {
    sel = (sel + pg->shown < n ? sel + pg->shown : n - 1);
  }
  else if (c == KEY_PAGEUP) {
    sel = (sel - pg->shown >= 0 ? sel - pg->shown : 0);
  }
  pg->selected = sel;
  pg->expanded = true;
}

static void edit_completion_menu(ic_env_t* env, editor_t* eb, bool more_available) {
  pager_t pg;
  memset(&pg, 0, sizeof(pg));
  pg.selected = -1;
  code_t c;
  eb->burst = false;   // each preview needs its own undo step

again:
  pg.count = completions_count(env->completions);
  if (pg.count <= 0) {
    pager_close(env, eb, &pg);
    return;
  }
  pager_layout(env, eb, &pg);
  pager_render(env, eb, &pg, more_available);
  if (pg.selected >= 0) {
    // show the selection in the line, but keep the line as it was until it is taken
    if (edit_complete(env, eb, pg.selected)) editor_undo_restore(eb, false);
    else edit_refresh(env, eb);
  }
  else {
    edit_refresh(env, eb);
  }

  do {
    c = tty_read(env->tty);
    if (tty_term_resize_event(env->tty)) {
      edit_resize(env, eb);
      goto again;
    }
  } while (c == KEY_NONE);

  if (c == KEY_TAB || c == KEY_SHIFT_TAB || c == KEY_DOWN || c == KEY_UP ||
      c == KEY_PAGEDOWN || c == KEY_PAGEUP ||
      (pg.selected >= 0 && (c == KEY_LEFT || c == KEY_RIGHT))) {
    pager_move(&pg, c);
    goto again;
  }
  if (c == KEY_ESC) {
    pager_close(env, eb, &pg);
    return;
  }
  if (c == KEY_BACKSP || (pg.selected < 0 && c != ' ' && (code_is_ascii_char(c, NULL) || (code_is_unicode(c, NULL) && c >= 0x80)))) {
    // typing narrows the list (and a backspace widens it) as in fish
    if (c == KEY_BACKSP) {
      if (eb->pos <= 0) goto again;
      editor_start_modify(eb);
      eb->pos = sbuf_delete_char_before(eb->input, eb->pos);
    }
    else {
      editor_start_modify(eb);
      ssize_t next = sbuf_insert_unicode_at(eb->input, (unicode_t)c, eb->pos);
      if (next >= 0) eb->pos = next;
    }
    pg.selected = -1;
    pg.first = 0;
    completions_generate(env, env->completions, sbuf_string(eb->input), eb->pos, IC_MAX_COMPLETIONS_TO_SHOW);
    more_available = (completions_count(env->completions) >= IC_MAX_COMPLETIONS_TO_SHOW);
    completions_sort(env->completions);
    goto again;
  }
  // anything else takes the selection, closes the pager and does its usual job
  if (pg.selected >= 0) {
    edit_complete(env, eb, pg.selected);
    if (c == KEY_ENTER) c = 0;   // enter only takes it
  }
  mem_free(env->mem, pg.colw);
  sbuf_clear(eb->extra);
  completions_clear(env->completions);
  edit_refresh(env, eb);
  if (c != 0) tty_code_pushback(env->tty, c);
}

static void edit_generate_completions(ic_env_t* env, editor_t* eb, bool autotab) {
  debug_msg( "edit: complete: %zd: %s\n", eb->pos, sbuf_string(eb->input) );
  if (eb->pos < 0) return;
  ssize_t count = completions_generate(env, env->completions, sbuf_string(eb->input), eb->pos, IC_MAX_COMPLETIONS_TO_SHOW);
  bool more_available = (count >= IC_MAX_COMPLETIONS_TO_SHOW);
  if (count <= 0) {
    // no completions
    if (!autotab) { term_beep(env->term); }
  }
  else if (count == 1) {
    // complete if only one match    
    if (edit_complete(env,eb,0 /*idx*/) && env->complete_autotab) {
      tty_code_pushback(env->tty,KEY_EVENT_AUTOTAB);
    }    
  }
  else {
    if (!more_available) { 
      edit_complete_longest_prefix(env,eb);
    }    
    completions_sort(env->completions);
    edit_completion_menu( env, eb, more_available);    
  }
}
