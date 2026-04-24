default: venv
	. .venv/bin/activate && sphinx-build \
		--fail-on-warning \
		. \
		../public

venv: .venv/done
.venv/done:
	python3 -m venv .venv
	. .venv/bin/activate && pip install "pmos-theme @ git+https://gitlab.postmarketos.org/postmarketOS/docs.postmarketos.org.git/#subdirectory=theme"
	touch $@

run:
	python3 -m http.server -b 127.0.0.1 8081 -d ../public

.PHONY: default venv run
