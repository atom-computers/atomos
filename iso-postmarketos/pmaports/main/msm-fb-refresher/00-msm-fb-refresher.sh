#!/bin/sh
/usr/sbin/msm-fb-refresher --loop &
{
	echo "#!/bin/sh"
	echo "kill $!"
} > /hooks-cleanup/msm-fb-refresher-cleanup.sh
