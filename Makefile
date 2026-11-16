CC ?= cc
CFLAGS ?= -O2 -std=c11 -Wall -Wextra -Werror
.PHONY: server macos test clean
server: bin/remote-stats-server
bin/remote-stats-server: server/collector.c
	mkdir -p bin
	$(CC) $(CFLAGS) $< -lm -o $@.tmp
	mv $@.tmp $@
macos:
	./scripts/build-macos.sh
test:
	python3 -m unittest discover -s tests -v
clean:
	rm -rf bin build
