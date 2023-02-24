SHELL = /bin/bash -o pipefail
MAKEFLAGS += --no-print-directory
ifndef DEBUG
.SILENT:
endif

all: test format ts verify

build: ts

test: zig/zig
	TZ=UTC zig/zig test src/ts.zig -lc

format: zig/zig
	zig/zig fmt src/ts.zig

validate-format: zig/zig
	zig/zig fmt src/ts.zig --check

clean: 
	rm -rf ts ts.o zig-out zig-cache ts.pl

zig/zig:
	./install-zig.sh

verify: ts
	yes "Sample text" 2>/dev/null | head -n 10 | ./ts -m '%.T' || true

benchmark: ts.pl ts
	echo "Benchmarking src/ts.zig"
	make benchmark-ts-zig
	echo "Benchmarking ts.pl"
	make benchmark-ts-pl

benchmark-ts-zig: ts
	time yes "Sample text" 2>/dev/null | head -n 3000000 | ./ts -m '%.T' >/dev/null || true

benchmark-ts-pl: ts.pl
	time yes "Sample text" 2>/dev/null | head -n 3000000 | ./ts.pl -m '%.T' >/dev/null || true

ts.pl:
	wget -q https://raw.githubusercontent.com/stigtsp/moreutils/master/ts -O $@
	chmod +x $@

%: src/%.zig zig/zig Makefile build.zig
	./zig/zig build-exe src/ts.zig
	touch $@
