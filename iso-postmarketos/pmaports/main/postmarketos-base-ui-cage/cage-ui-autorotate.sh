#!/bin/sh

set -ueo pipefail

CONNECTORS=$(drm_info -j 2>/dev/null | jq -rc '[.[].connectors | .[] | select( .status == 1 )]')

while read -r CONNECTOR ; do
	CONNECTOR_ID=$(echo "$CONNECTOR" | jq -rc '.id')
	[ "null" == "$CONNECTOR_ID" ] && continue

	ROTATION=$(echo "$CONNECTOR" | jq -rc '.properties."panel orientation"')
	[ "null" == "$ROTATION" ] && continue

	ROTATION_VALUE=$(echo "$ROTATION" | jq -rc '.value')
	[ "null" == "$ROTATION_VALUE" ] && continue

	ROTATION_LABEL=$(echo "$ROTATION" | jq -rc '.spec | .[] | select( .value == '$ROTATION_VALUE' ) | .name')
	[ "null" == "$ROTATION_LABEL" ] && continue

	OUTPUT_NAME=none
	for CONN_ID in /sys/class/drm/*/connector_id; do
		if [ "$CONNECTOR_ID" == $(cat $CONN_ID) ]; then
			OUTPUT_NAME=$(dirname "$CONN_ID")
			OUTPUT_NAME=${OUTPUT_NAME#*/card?-}
		fi
	done
	[ "none" == "$OUTPUT_NAME" ] && continue

	case "$ROTATION_LABEL" in
		"Normal")
			;;
		"Upside Down")
			wlr-randr --output "$OUTPUT_NAME" --transform 180
			;;
		"Left Side Up")
			wlr-randr --output "$OUTPUT_NAME" --transform  90
			;;
		"Right Side Up")
			wlr-randr --output "$OUTPUT_NAME" --transform 270
			;;
		*)
			echo "Connector $CONNECTOR_ID: Unsupported rotation: $ROTATION_LABEL"
			;;
	esac
done < <(echo "$CONNECTORS" | jq -rc .[])
