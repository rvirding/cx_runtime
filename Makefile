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
	mkdir -p $(INSTALL_DIR)
	cp concurix.config $(INSTALL_DIR)/concurix.config
	cp -r src $(INSTALL_DIR)/src
	cp -r ebin $(INSTALL_DIR)/ebin
	cp -r test $(INSTALL_DIR)/test
	cp scripts/concurix_runtime.boot $(ROOT)/bin/concurix_runtime.boot
	cp scripts/concurix_runtime.boot $(ROOT)/releases/R15B02/concurix_runtime.boot
	cp scripts/concurix_runtime.script $(ROOT)/releases/R15B02/concurix_runtime.script

