REBAR:=$(shell which rebar 2> /dev/null || echo ./rebar)

DESTDIR              = /usr/local/lib/erlang
CXRUN_INSTALL_DIR    = $(DESTDIR)/lib/concurix_runtime-0.1

GPROC_SRC_DIR        = deps/gproc
GPROC_INSTALL_DIR    = $(DESTDIR)/lib/gproc-0.2.15

MOCHI_SRC_DIR        = deps/mochiweb
MOCHI_INSTALL_DIR    = $(DESTDIR)/lib/mochiweb-2.3.0

ERLCLOUD_SRC_DIR     = deps/erlcloud
ERLCLOUD_INSTALL_DIR = $(DESTDIR)/lib/erlcloud-0.4.1

.PHONY: all erl test clean doc install release

all: erl

erl:
	$(REBAR) get-deps compile

test: all
	@mkdir -p .eunit
	$(REBAR) skip_deps=true eunit

clean:
	$(REBAR) clean
	-rm scripts/concurix_runtime.script scripts/concurix_runtime.boot
	-rm -rvf deps ebin doc .eunit

doc:
	$(REBAR) doc




install-erlcloud:
	cd deps/erlcloud && make install
	install -d $(ERLCLOUD_INSTALL_DIR)
	install -d $(ERLCLOUD_INSTALL_DIR)/ebin
	install -m 644 $(ERLCLOUD_SRC_DIR)/ebin/erlcloud.app $(ERLCLOUD_INSTALL_DIR)/ebin
	install -m 644 $(ERLCLOUD_SRC_DIR)/ebin/*.beam       $(ERLCLOUD_INSTALL_DIR)/ebin

install-gproc:
	install -d $(GPROC_INSTALL_DIR)
	install -d $(GPROC_INSTALL_DIR)/doc
	install -d $(GPROC_INSTALL_DIR)/ebin
	install -m 644 $(GPROC_SRC_DIR)/doc/*                $(GPROC_INSTALL_DIR)/doc
	install -m 644 $(GPROC_SRC_DIR)/ebin/gproc.app       $(GPROC_INSTALL_DIR)/ebin
	install -m 644 $(GPROC_SRC_DIR)/ebin/*.beam          $(GPROC_INSTALL_DIR)/ebin

install-mochiweb:
	install -d $(MOCHI_INSTALL_DIR)
	install -d $(MOCHI_INSTALL_DIR)/ebin
	install -m 644 $(MOCHI_SRC_DIR)/ebin/mochiweb.app    $(MOCHI_INSTALL_DIR)/ebin
	install -m 644 $(MOCHI_SRC_DIR)/ebin/*.beam          $(MOCHI_INSTALL_DIR)/ebin

install-cx-runtime: 
	install -d $(CXRUN_INSTALL_DIR)
	install -d $(CXRUN_INSTALL_DIR)/ebin
	install -m 644 ebin/concurix_runtime.app             $(CXRUN_INSTALL_DIR)/ebin
	install -m 644 ebin/*.beam                           $(CXRUN_INSTALL_DIR)/ebin

install: install-erlcloud install-gproc install-mochiweb install-cx-runtime




release:
	scripts/release

install-cx-boot: install
	install scripts/concurix_runtime.boot             $(DESTDIR)/bin
	install scripts/concurix_runtime.boot             $(DESTDIR)/releases/R15B02
	install scripts/concurix_runtime.script           $(DESTDIR)/releases/R15B02

