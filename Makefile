REBAR:=$(shell which rebar 2> /dev/null || echo ./rebar)

ROOT              = /usr/local/lib/erlang
CXRUN_INSTALL_DIR = $(ROOT)/lib/concurix_runtime-0.1

GPROC_SRC_DIR     = deps/gproc
GPROC_INSTALL_DIR = $(ROOT)/lib/gproc-0.2.15

MOCHI_SRC_DIR     = deps/mochiweb
MOCHI_INSTALL_DIR = $(ROOT)/lib/mochiweb-2.3.0

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

release:
	scripts/release

install-cowboy:
	cd deps/cowboy   && make install

install-erlcloud:
	cd deps/erlcloud && make install

install-purity:
	cd deps/purity   && make install

install-gproc:
	install -d $(GPROC_INSTALL_DIR)
	install -d $(GPROC_INSTALL_DIR)/doc
	install -d $(GPROC_INSTALL_DIR)/ebin
	install -m 644 $(GPROC_SRC_DIR)/doc/*             $(GPROC_INSTALL_DIR)/doc
	install -m 644 $(GPROC_SRC_DIR)/ebin/gproc.app    $(GPROC_INSTALL_DIR)/ebin
	install -m 644 $(GPROC_SRC_DIR)/ebin/*.beam       $(GPROC_INSTALL_DIR)/ebin

install-mochiweb:
	install -d $(MOCHI_INSTALL_DIR)
	install -d $(MOCHI_INSTALL_DIR)/ebin
	install -m 644 $(MOCHI_SRC_DIR)/ebin/mochiweb.app $(MOCHI_INSTALL_DIR)/ebin
	install -m 644 $(MOCHI_SRC_DIR)/ebin/*.beam       $(MOCHI_INSTALL_DIR)/ebin

install-cx-runtime: 
	install -d $(CXRUN_INSTALL_DIR)
	install -d $(CXRUN_INSTALL_DIR)/ebin
	install -m 644 ebin/concurix_runtime.app          $(CXRUN_INSTALL_DIR)/ebin
	install -m 644 ebin/*.beam                        $(CXRUN_INSTALL_DIR)/ebin
	install scripts/concurix_runtime.boot             $(ROOT)/bin
	install scripts/concurix_runtime.boot             $(ROOT)/releases/R15B02
	install scripts/concurix_runtime.script           $(ROOT)/releases/R15B02

install: release install-cowboy install-erlcloud install-purity install-gproc install-mochiweb install-cx-runtime
