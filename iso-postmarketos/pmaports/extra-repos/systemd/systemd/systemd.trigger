#!/bin/sh
# When adding new paths to trigger on here, make sure to also add them in
# triggers= in the APKBUILD.
TRIGGERPATHS="$*"
SYSTEM_SERVICES_CHANGED=false
USER_SERVICES_CHANGED=false

# All the things we can do even if systemd isn't running
trigger_always() {
	for triggerpath in $TRIGGERPATHS; do
		case "$triggerpath" in
			/usr/lib/systemd/catalog)
				echo "Running journalctl --update-catalog..."
				journalctl --update-catalog
				;;
			/usr/lib/udev/hwdb.d)
				echo "Running systemd-hwdb update..."
				systemd-hwdb update
				;;
			/usr/lib/sysusers.d)
				echo "Running systemd-sysusers..."
				systemd-sysusers
				;;
			/usr/lib/systemd/system|/etc/systemd/system)
				SYSTEM_SERVICES_CHANGED=true
				;;
			/usr/lib/systemd/user|/etc/systemd/user)
				USER_SERVICES_CHANGED=true
				;;
		esac
	done
}

trigger_systemd_running() {
	for triggerpath in $TRIGGERPATHS; do
		case "$triggerpath" in
			/usr/lib/binfmt.d)
				echo "Running systemd-binfmt..."
				/usr/lib/systemd/systemd-binfmt
				;;
			/usr/lib/tmpfiles.d)
				echo "Running systemd-tmpfiles --create..."
				systemd-tmpfiles --create
				;;
			/usr/lib/udev/rules.d)
				# We can't do this as a trigger for the udevd
				# subpackage because it might end up running AFTER the
				# systemd trigger.
				echo "Marking systemd-udevd for reload..."
				systemctl set-property systemd-udevd.service Markers=+needs-reload
				;;
			/usr/lib/sysctl.d)
				echo "Running systemd-sysctl..."
				/usr/lib/systemd/systemd-sysctl
				;;
		esac
	done
}

trigger_user_and_system_services() {
	if $SYSTEM_SERVICES_CHANGED || $USER_SERVICES_CHANGED; then
		echo "Running systemd daemon-reload..."
		systemctl daemon-reload
	fi

	# This doesn't do anything yet but will trigger a daemon-reexec once we
	# upgrade to systemd 257:
	# https://github.com/systemd/systemd/commit/a375e145190482e8a2f0971bffb332e31211622f
	if $USER_SERVICES_CHANGED; then
		echo "Running systemd reload user@*.service..."
		systemctl reload "user@*.service"
	fi

	# Reload or restart marked system units. Units get marked in their
	# respective package post-upgrade scripts
	if $SYSTEM_SERVICES_CHANGED; then
		echo "Reloading/restarting marked system services..."
		systemctl enqueue-marked
	fi

	if $USER_SERVICES_CHANGED; then
		local uids
		uids="$(systemctl list-units 'user@*' --legend=no \
				| sed -n -r 's/.*user@([0-9]+).service.*/\1/p')"
		for uid in $uids; do
			echo "Reloading/restarting marked user services for uid=$uid..."
			systemctl \
				--user \
				-M "$uid@" \
				enqueue-marked &
		done
		wait
	fi
}

trigger_always

if ! [ -d "/run/systemd/system" ]; then
	echo "Skipping other triggers because systemd isn't running"
	exit 0
fi

trigger_systemd_running
trigger_user_and_system_services

exit 0
