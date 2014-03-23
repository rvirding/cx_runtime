ERLANG_DIALYZER_APPS = \
	erts \
	kernel \
	stdlib \
	crypto \
	public_key \
	inets \
	xmerl \
	sasl \
	mnesia

REBAR:=$(shell which rebar 2> /dev/null || echo ./rebar)

DESTDIR              = /usr/local/lib/erlang
CXRUN_INSTALL_DIR    = $(DESTDIR)/lib/concurix_runtime-0.1

.PHONY: all erl test clean doc install release xcompile

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

install-cx-runtime: 
	install -d $(CXRUN_INSTALL_DIR)
	install -d $(CXRUN_INSTALL_DIR)/ebin
	install -m 644 ebin/concurix_runtime.app             $(CXRUN_INSTALL_DIR)/ebin
	install -m 644 ebin/*.beam                           $(CXRUN_INSTALL_DIR)/ebin

install: install-cx-runtime

xcompile:
	$(REBAR) compile xref skip_deps=true

release:
	scripts/release

.dialyzer_plt:
	dialyzer --output_plt .dialyzer_plt --build_plt --apps $(ERLANG_DIALYZER_APPS)

analyze: erl .dialyzer_plt
	dialyzer --no_check_plt --no_native -Wrace_conditions -Wno_return --plt .dialyzer_plt --apps ebin

install-cx-boot: install
	install scripts/concurix_runtime.boot                $(DESTDIR)/bin
	install scripts/concurix_runtime.boot                $(DESTDIR)/releases/R15B02
	install scripts/concurix_runtime.script              $(DESTDIR)/releases/R15B02
