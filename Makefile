PREFIX ?= /usr/local
DESTDIR ?=
LIBDIR := $(PREFIX)/lib/ani-sync

.PHONY: install uninstall check

install:
	install -Dm755 ani-sync $(DESTDIR)$(LIBDIR)/ani-sync
	install -Dm644 -t $(DESTDIR)$(LIBDIR)/lib lib/*.sh
	install -Dm755 -t $(DESTDIR)$(LIBDIR)/libexec libexec/*
	install -dm755 $(DESTDIR)$(PREFIX)/bin
	ln -sf ../lib/ani-sync/ani-sync $(DESTDIR)$(PREFIX)/bin/ani-sync
	install -Dm644 -t $(DESTDIR)$(PREFIX)/share/doc/ani-sync README.md

uninstall:
	rm -rf $(DESTDIR)$(LIBDIR) $(DESTDIR)$(PREFIX)/share/doc/ani-sync
	rm -f $(DESTDIR)$(PREFIX)/bin/ani-sync

check:
	@for f in ani-sync lib/*.sh libexec/*; do bash -n "$$f" || exit 1; done
	@echo "syntax ok"
