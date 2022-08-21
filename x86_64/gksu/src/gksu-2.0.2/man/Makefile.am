man_MANS = gksu.1
EXTRA_DIST = gksu.1

install-data-hook:
	cd $(DESTDIR)$(mandir)/man1 && \
		$(LN_S) -f gksu.1 gksudo.1
