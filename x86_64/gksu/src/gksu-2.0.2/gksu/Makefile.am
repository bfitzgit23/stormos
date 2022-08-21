AM_CFLAGS = -g -O2 -Wall
INCLUDES = @GKSU_CFLAGS@
AM_CPPFLAGS = -DLOCALEDIR=\"$(datadir)/locale\" -DDATA_DIR=\"$(datadir)\" -DPREFIX=\"$(prefix)\"

bin_PROGRAMS = gksu

noinst_HEADERS = defines.h

gksu_LDFLAGS = @GKSU_LIBS@ -lutil
gksu_SOURCES = gksu.c

install-exec-hook:
	cd $(DESTDIR)$(bindir) && \
		$(LN_S) -f gksu gksudo

