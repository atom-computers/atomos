#!/bin/sh

log() {
	echo "$@" | logger -t "postmarketOS:modem-setup"
}

QMBNCFG_CONFIG="1"

if [ -z "$1" ]
then
	DEV="/dev/EG25.AT"
else
	DEV="$1"
fi

# Read current config
QMBNCFG_ACTUAL_CONFIG=$(echo 'AT+QMBNCFG="AutoSel"' | atinout - $DEV -)

if echo $QMBNCFG_ACTUAL_CONFIG | grep -q $QMBNCFG_CONFIG
then
	log "Modem already configured"
	exit 0
fi


# Configure VoLTE auto selecting profile
RET=$(echo "AT+QMBNCFG=\"AutoSel\",$QMBNCFG_CONFIG" | atinout - $DEV -)
if ! echo $RET | grep -q OK
then
	log "Failed to enable VoLTE profile auto selecting: $RET"
	exit 1
fi
