#!/sbin/openrc-run

description="AT modem emulation using libsamsung-ipc"
depends="ppp"

command="env"
command_args="samsungipcd /dev/ptywc /dev/ptywd"
supervisor="supervise-daemon"

if [[ -n "$IPC_DEVICE_NAME" ]]
then
	command_args="IPC_DEVICE_NAME=$IPC_DEVICE_NAME $command_args"
fi

if [[ -n "$IPC_DEVICE_BOARD_NAME" ]]
then
	command_args="IPC_DEVICE_BOARD_NAME=$IPC_DEVICE_BOARD_NAME $command_args"
fi
