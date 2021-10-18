# VARIABLES
SHELL = /bin/sh
NAME = scripts

PREFIX ?= /usr/local
SCRIPTS := $(wildcard ./.local/bin/*)

install:
	install -Dm 775 $(SCRIPTS) -t $(DESTDIR)$(PREFIX)/bin/

.PHONY: install


