.PHONY: check lint test

check: lint test

lint:
	shellcheck tmux-history-guard.tmux scripts/*.sh tests/*.sh

test:
	./tests/run.sh
