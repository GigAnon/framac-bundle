# MOCK why3 build: a CLI whose libdir is <exe>/../lib/why3 when relocatable,
# the --prefix one otherwise, and its commands / plugins
include config.mk
all:
	@echo "mock why3 build (relocatable: $(RELOC))"
install:
	mkdir -p $(PREFIX)/bin $(PREFIX)/lib/why3/commands $(PREFIX)/lib/why3/plugins $(PREFIX)/share/why3
	sed -e 's|@RELOC@|$(RELOC)|' -e 's|@WHY3LIB@|$(PREFIX)/lib/why3|' -e 's|@WHY3DATA@|$(PREFIX)/share/why3|' why3.in > $(PREFIX)/bin/why3
	chmod 755 $(PREFIX)/bin/why3
	for c in config prove replay session; do echo "mock cmxs (reloc build)" > $(PREFIX)/lib/why3/commands/why3$$c.cmxs; done
	echo "mock cmxs (reloc build)" > $(PREFIX)/lib/why3/plugins/tptp.cmxs
