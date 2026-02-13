# GPG Key Generation
# Ensures we have a keypair for signing the ISO repository and validating it in the Live system.

$(BUILD)/iso-key.gpg:
	mkdir -p "$(BUILD)"
	if [ ! -f "$@" ]; then \
		gpg --batch --passphrase '' --quick-gen-key "AtomOS Builder" default default never; \
		gpg --export-secret-keys "AtomOS Builder" > "$@"; \
	fi

$(BUILD)/iso-pub.gpg: $(BUILD)/iso-key.gpg
	gpg --export "AtomOS Builder" > "$@"
