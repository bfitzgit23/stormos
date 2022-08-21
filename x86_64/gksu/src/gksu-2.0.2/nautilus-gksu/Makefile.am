AM_CFLAGS = -g -O2 -Wall
INCLUDES = ${NAUTILUS_CFLAGS}
AM_CPPFLAGS = -DLOCALEDIR=\"$(datadir)/locale\" -DDATA_DIR=\"$(datadir)\" -DPREFIX=\"$(prefix)\"

nautilus_extensiondir=$(libdir)/nautilus/extensions-2.0
nautilus_extension_LTLIBRARIES = libnautilus-gksu.la
libnautilus_gksu_la_SOURCES = libnautilus-gksu.c
libnautilus_gksu_la_LDFLAGS = LDFLAGS = -module -avoid-version -no-undefined
libnautilus_gksu_la_LIBADD  = $(NAUTILUS_LIBS)
