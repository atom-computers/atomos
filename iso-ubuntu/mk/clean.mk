# Clean targets

clean:
	sudo rm -rf build/

clean-iso:
	sudo rm -rf $(BUILD)/iso $(BUILD)/iso_*.tag $(ISO) $(ISO).zsync

clean-chroot:
	sudo rm -rf $(BUILD)/chroot $(BUILD)/chroot.tag

clean-live:
	sudo rm -rf $(BUILD)/live $(BUILD)/live.tag

.PHONY: clean clean-iso clean-chroot clean-live
