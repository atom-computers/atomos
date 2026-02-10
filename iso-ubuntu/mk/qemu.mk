# QEMU testing targets

QEMU_MEM?=4096
QEMU_SMP?=4

qemu: $(ISO)
	qemu-system-x86_64 \
		-enable-kvm \
		-m $(QEMU_MEM) \
		-smp $(QEMU_SMP) \
		-cdrom $(ISO) \
		-boot d \
		-vga virtio \
		-display gtk,gl=on

qemu-bios: $(ISO)
	qemu-system-x86_64 \
		-m $(QEMU_MEM) \
		-smp $(QEMU_SMP) \
		-cdrom $(ISO) \
		-boot d \
		-vga virtio

qemu-uefi: $(ISO)
	qemu-system-x86_64 \
		-enable-kvm \
		-m $(QEMU_MEM) \
		-smp $(QEMU_SMP) \
		-bios /usr/share/ovmf/OVMF.fd \
		-cdrom $(ISO) \
		-boot d \
		-vga virtio \
		-display gtk,gl=on

.PHONY: qemu qemu-bios qemu-uefi
