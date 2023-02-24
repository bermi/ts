SHELL = /bin/bash -o pipefail
MAKEFLAGS += --no-print-directory
ifndef DEBUG
.SILENT:
endif

all: test format ts verify

test:
	TZ=UTC zig/zig test ts.zig

format:
	zig/zig fmt ts.zig

clean: 
	rm -rf ts ts.o zig-out zig-cache ts.pl

zig/zig:
	./scripts/install-zig.sh

verify: ts
	yes "Sample text" 2>/dev/null | head -n 10 | ./ts -m '%.T' || true

benchmark: ts.pl ts
	echo "Benchmarking ts.zig"
	make performance-ts-zig
	echo "Benchmarking ts.pl"
	make performance-ts-pl

performance-ts-zig: ts
	yes "Sample text" 2>/dev/null | head -n 3000000 | ./ts -m '%.T' | pv -l >/dev/null || true

performance-ts-pl: ts.pl
	yes "Sample text" 2>/dev/null | head -n 3000000 | ./ts.pl -m '%.T' | pv -l >/dev/null || true

ts.pl:
	wget -q https://raw.githubusercontent.com/stigtsp/moreutils/master/ts -O $@
	chmod +x $@

%: %.zig zig/zig
	./zig/zig build-exe -freference-trace -Drelease-fast ts.zig
	touch $@
