# ISO creation targets

$(BUILD)/iso_create.tag:
	# Remove old ISO
	sudo rm -rf "$(BUILD)/iso"
	
	# Create new ISO directory
	mkdir -p "$(BUILD)/iso"
	
	touch "$@"

$(BUILD)/iso_casper.tag: $(BUILD)/live.tag $(BUILD)/iso_create.tag
	# Remove old casper directory
	sudo rm -rf "$(BUILD)/iso/casper"
	
	# Create new casper directory
	mkdir -p "$(BUILD)/iso/$(CASPER_PATH)"
	
	# Copy kernel
	sudo cp "$(BUILD)/live/boot/vmlinuz" "$(BUILD)/iso/$(CASPER_PATH)/vmlinuz.efi" || \
		sudo cp "$(BUILD)/live/vmlinuz" "$(BUILD)/iso/$(CASPER_PATH)/vmlinuz.efi"
	
	# Copy initrd
	sudo cp "$(BUILD)/live/boot/initrd.img" "$(BUILD)/iso/$(CASPER_PATH)/initrd.gz" || \
		sudo cp "$(BUILD)/live/initrd.img" "$(BUILD)/iso/$(CASPER_PATH)/initrd.gz"
	
	# Create manifests
	cp "$(BUILD)/live.tag" "$(BUILD)/iso/$(CASPER_PATH)/filesystem.manifest"
	grep -F -x -v -f "$(BUILD)/chroot.tag" "$(BUILD)/live.tag" | cut -f1 > "$(BUILD)/iso/$(CASPER_PATH)/filesystem.manifest-remove" || true
	
	# Calculate filesystem size
	sudo du -sx --block-size=1 "$(BUILD)/live" | cut -f1 > "$(BUILD)/iso/$(CASPER_PATH)/filesystem.size"
	
	# Create squashfs
	sudo mksquashfs "$(BUILD)/live" \
		"$(BUILD)/iso/$(CASPER_PATH)/filesystem.squashfs" \
		-noappend -fstime "$(DISTRO_EPOCH)" \
		-comp xz -b 1M -Xdict-size 1M
	
	# Fix permissions
	sudo chown -R "$(USER):$(USER)" "$(BUILD)/iso/$(CASPER_PATH)"
	
	touch "$@"

$(BUILD)/iso_grub.tag: $(BUILD)/iso_create.tag
	# Create boot directory
	mkdir -p "$(BUILD)/iso/boot/grub"
	
	# Copy GRUB configuration
	sed "$(SED)" "data/grub/grub.cfg" > "$(BUILD)/iso/boot/grub/grub.cfg"
	
	# Copy GRUB font
	cp /usr/share/grub/unicode.pf2 "$(BUILD)/iso/boot/grub/font.pf2" || true
	
	# Create EFI boot directory
	mkdir -p "$(BUILD)/iso/efi/boot"

ifneq ($(DISTRO_ARCH),amd64)
	# Create GRUB EFI image for ARM64
	grub-mkstandalone \
		--format=arm64-efi \
		--output="$(BUILD)/iso/efi/boot/bootaa64.efi" \
		--locales="" \
		--fonts="" \
		"boot/grub/grub.cfg=$(BUILD)/iso/boot/grub/grub.cfg"
else
	# Create GRUB EFI image for AMD64
	grub-mkstandalone \
		--format=x86_64-efi \
		--output="$(BUILD)/iso/efi/boot/bootx64.efi" \
		--locales="" \
		--fonts="" \
		"boot/grub/grub.cfg=$(BUILD)/iso/boot/grub/grub.cfg"
endif
	
	# Create EFI image
	dd if=/dev/zero of="$(BUILD)/iso/boot/grub/efi.img" bs=1M count=10
	mkfs.vfat "$(BUILD)/iso/boot/grub/efi.img"
	mmd -i "$(BUILD)/iso/boot/grub/efi.img" efi efi/boot

ifneq ($(DISTRO_ARCH),amd64)
	mcopy -i "$(BUILD)/iso/boot/grub/efi.img" "$(BUILD)/iso/efi/boot/bootaa64.efi" ::efi/boot/
else
	mcopy -i "$(BUILD)/iso/boot/grub/efi.img" "$(BUILD)/iso/efi/boot/bootx64.efi" ::efi/boot/
endif
	
	touch "$@"

$(BUILD)/iso_data.tag: $(BUILD)/iso_create.tag
	# Create .disk directory
	mkdir -p "$(BUILD)/iso/.disk"
	sed "$(SED)" "data/disk/info" > "$(BUILD)/iso/.disk/info"
	echo "$(DISTRO_VOLUME_LABEL)" > "$(BUILD)/iso/.disk/info"
	
	touch "$@"

$(BUILD)/iso_sum.tag: $(BUILD)/iso_casper.tag $(BUILD)/iso_grub.tag $(BUILD)/iso_data.tag
	# Calculate md5sum
	cd "$(BUILD)/iso" && \
	rm -f md5sum.txt && \
	find -type f -print0 | sort -z | xargs -0 md5sum > md5sum.txt
	
	touch "$@"

$(ISO): $(BUILD)/iso_sum.tag
ifeq ($(DISTRO_ARCH),amd64)
	xorriso -as mkisofs \
		-J -l -R \
		-V "$(DISTRO_VOLUME_LABEL)" \
		-o "$@.partial" \
		-b boot/grub/efi.img \
		-no-emul-boot \
		-boot-load-size 4 \
		-boot-info-table \
		-eltorito-alt-boot \
		-e boot/grub/efi.img \
		-no-emul-boot \
		-isohybrid-gpt-basdat \
		"$(BUILD)/iso"
else
	xorriso -as mkisofs \
		-J -l -R \
		-V "$(DISTRO_VOLUME_LABEL)" \
		-o "$@.partial" \
		-e boot/grub/efi.img \
		-no-emul-boot \
		-isohybrid-gpt-basdat \
		"$(BUILD)/iso"
endif
	
	mv "$@.partial" "$@"

$(ISO).zsync: $(ISO)
	cd "$(BUILD)" && zsyncmake -o "`basename "$@.partial"`" "`basename "$<"`"
	mv "$@.partial" "$@"

$(BUILD)/SHA256SUMS: $(ISO)
	cd "$(BUILD)" && sha256sum -b "`basename "$<"`" > "`basename "$@.partial"`"
	mv "$@.partial" "$@"

$(BUILD)/SHA256SUMS.gpg: $(BUILD)/SHA256SUMS
	cd "$(BUILD)" && gpg --batch --yes --output "`basename "$@.partial"`" --detach-sig "`basename "$<"`"
	mv "$@.partial" "$@"

.PHONY: iso-create iso-casper iso-grub iso-data iso-sum
