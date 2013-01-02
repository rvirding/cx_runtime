REBAR:=$(shell which rebar || echo ./rebar)

ROOT=/usr/local/lib/erlang
INSTALL_DIR=$(ROOT)/lib/concurix_runtime-0.1

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

install: release
	cd deps/erlcloud && make install
	cd deps/purity && make install
	install -d $(INSTALL_DIR)
	install concurix.config $(INSTALL_DIR)
	install -d $(INSTALL_DIR)/src
	install	src/*.erl $(INSTALL_DIR)/src
	install ebin/*.beam ebin/concurix_runtime.app $(INSTALL_DIR)/ebin
	install test/* $(INSTALL_DIR)/test
	install scripts/concurix_runtime.boot $(ROOT)/bin
	install scripts/concurix_runtime.boot $(ROOT)/releases/R15B02
	install scripts/concurix_runtime.script $(ROOT)/releases/R15B02

