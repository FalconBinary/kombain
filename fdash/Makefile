# Builds fdash from the vendored dash and isocline. No autotools needed.
#   make            optimized, stripped binary at ./fdash
#   make install    PREFIX=/usr/local
#   make test

CC       ?= cc
PREFIX   ?= /usr/local
BINDIR   ?= $(PREFIX)/bin
DATADIR  ?= $(PREFIX)/share/fdash
OPT      ?= -O2 -flto -ffunction-sections -fdata-sections -fno-plt -fstack-protector-strong -D_FORTIFY_SOURCE=2 -D_GNU_SOURCE
LINKOPT  ?= -flto -Wl,--gc-sections -Wl,-z,relro,-z,now -Wl,--as-needed -s

TARGET   ?= fdash
DASH     := dash
BUILD    ?= build
STAMP    := $(BUILD)/.configured
OBJS     := $(patsubst src/%.c,$(BUILD)/%.o,$(wildcard src/*.c)) $(BUILD)/isocline.o
DASHSRC  := $(wildcard $(DASH)/src/*.c $(DASH)/src/*.h $(DASH)/src/builtins.def.in)
COMMON   := -DFDASH -I$(CURDIR)/src -I$(CURDIR)/isocline/include

all: $(TARGET)

$(STAMP): $(DASH)/configure
	mkdir -p $(BUILD)
	# git does not keep timestamps: stop automake from wanting to regenerate these
	touch $(DASH)/aclocal.m4 $(DASH)/configure $(DASH)/config.h.in $(DASH)/Makefile.in $(DASH)/src/Makefile.in
	cd $(BUILD) && ../$(DASH)/configure --without-libedit --enable-fnmatch --disable-silent-rules \
		CC="$(CC)" CFLAGS="$(OPT) -Wall" CPPFLAGS="$(COMMON)" >configure.log 2>&1 || { cat configure.log; exit 1; }
	touch $@

$(BUILD)/generated: $(STAMP) $(DASH)/src/builtins.def.in
	$(MAKE) -C $(BUILD)/src builtins.h nodes.h syntax.h token.h token_vars.h
	touch $@

$(BUILD)/%.o: src/%.c src/fdash.h src/util.h isocline/include/isocline.h $(BUILD)/generated
	$(CC) $(OPT) -Wall -Wextra -Wno-unused-parameter -std=gnu11 $(COMMON) -DSHELL -DBSD=1 \
		-DFDASH_DATADIR='"$(DATADIR)"' -include $(BUILD)/config.h \
		-I$(DASH)/src -I$(BUILD)/src -c $< -o $@

$(BUILD)/isocline.o: $(wildcard isocline/src/*.c isocline/src/*.h isocline/include/*.h)
	mkdir -p $(BUILD)
	$(CC) $(OPT) -w -std=gnu11 -Iisocline/include -c isocline/src/isocline.c -o $@

$(TARGET): $(OBJS) $(DASHSRC)
	rm -f $(BUILD)/src/dash
	$(MAKE) -C $(BUILD)/src dash LIBS="$(addprefix $(CURDIR)/,$(OBJS))" LDFLAGS="$(LINKOPT)"
	cp $(BUILD)/src/dash $@

install: $(TARGET)
	install -Dm755 $(TARGET) $(DESTDIR)$(BINDIR)/fdash
	sed 's|/usr/local/share/fdash|$(DATADIR)|' update-completions.sh >$(DESTDIR)$(BINDIR)/fdash-update-completions
	chmod 755 $(DESTDIR)$(BINDIR)/fdash-update-completions
	install -d $(DESTDIR)$(DATADIR)/completions
	install -m644 completions/* $(DESTDIR)$(DATADIR)/completions/
	install -d $(DESTDIR)$(DATADIR)/generators
	install -m755 generators/* $(DESTDIR)$(DATADIR)/generators/
	install -m644 config.sh.example $(DESTDIR)$(DATADIR)/config.sh.example

test: $(TARGET)
	python3 tests/run.py ./$(TARGET)

clean:
	rm -rf $(BUILD) $(TARGET)

.PHONY: all install test clean
