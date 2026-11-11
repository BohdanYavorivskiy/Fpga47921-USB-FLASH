import argparse
import os
from pathlib import Path
import sys
import threading
import time

VID = 0x1209
PID = 0x0001
EP_OUT = 0x01
EP_IN = 0x81
INTERFACE = 0
EP1_MAX_PACKET_SIZE = 32

FLASH_SIZE = 2 * 1024 * 1024

STATUS_MESSAGES = {
    0x00: "success",
    0x01: "invalid command length or argument",
    0x02: "unknown command",
}

SPI_STATUS_MESSAGES = {
    0x00: "transfer complete",
    0x01: "SPI master busy or invalid SPI value",
    0x02: "unknown command",
    0x03: "invalid SPI transfer length",
    0x04: "assert CS# before transferring",
}

SPI_DIVIDER_MIN = 1
SPI_DIVIDER_MAX = 15
FLASH_SPI_DIVIDER = SPI_DIVIDER_MAX


def load_pyusb():
    script_dir = Path(__file__).resolve().parent
    original_path = sys.path.copy()
    sys.path[:] = [
        entry
        for entry in sys.path
        if Path(entry or os.getcwd()).resolve() != script_dir
    ]
    try:
        import usb.core
        import usb.util
    except ModuleNotFoundError as exc:
        if exc.name == "usb" or (exc.name and exc.name.startswith("usb.")):
            raise RuntimeError(
                "PyUSB is not installed. Install it with: "
                "python -m pip install pyusb"
            ) from exc
        raise
    finally:
        sys.path[:] = original_path

    return usb.core, usb.util


def parse_milliseconds(value):
    try:
        milliseconds = int(value, 10)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc

    if not 1 <= milliseconds <= 0xFFFE:
        raise argparse.ArgumentTypeError("must be between 1 and 65534")
    return milliseconds


def get_endpoints(dev, usb_util):
    active_configuration = dev.ctrl_transfer(0x80, 0x08, 0, 0, 1)
    if len(active_configuration) != 1:
        raise RuntimeError("USB GET_CONFIGURATION returned an invalid response")
    if active_configuration[0] != 1:
        dev.set_configuration(1)
    config = dev.get_active_configuration()
    interface = config[(INTERFACE, 0)]

    out_ep = usb_util.find_descriptor(
        interface,
        custom_match=lambda ep: (
            ep.bEndpointAddress == EP_OUT
            and usb_util.endpoint_type(ep.bmAttributes)
            == usb_util.ENDPOINT_TYPE_BULK
        ),
    )
    in_ep = usb_util.find_descriptor(
        interface,
        custom_match=lambda ep: (
            ep.bEndpointAddress == EP_IN
            and usb_util.endpoint_type(ep.bmAttributes)
            == usb_util.ENDPOINT_TYPE_BULK
        ),
    )
    if out_ep is None or in_ep is None:
        raise RuntimeError(
            "USB device does not expose the expected bulk endpoints "
            f"OUT 0x{EP_OUT:02X} and IN 0x{EP_IN:02X}"
        )

    return interface, out_ep, in_ep


def send_command(
    dev, out_ep, in_ep, opcode, payload, response_length=2, status_messages=None
):
    if status_messages is None:
        status_messages = STATUS_MESSAGES

    command = bytes((opcode,)) + payload
    written = dev.write(out_ep, command, timeout=1000)
    if written != len(command):
        raise RuntimeError(
            f"USB command was only partially sent ({written}/{len(command)} bytes)"
        )

    response = bytes(dev.read(in_ep, EP1_MAX_PACKET_SIZE, timeout=1000))
    if len(response) != response_length:
        raise RuntimeError(
            f"Expected a {response_length}-byte USB response, "
            f"received {len(response)} bytes: {response.hex(' ')}. "
            "The endpoint returned an unexpected packet; USB session state "
            "may be out of sync."
        )

    response_opcode, status = response[:2]
    if response_opcode != opcode:
        raise RuntimeError(
            f"USB response opcode 0x{response_opcode:02X} does not match "
            f"command 0x{opcode:02X}; received {len(response)} bytes: "
            f"{response.hex(' ')}. The IN endpoint may have returned a stale "
            "or incorrectly sized response."
        )
    if status != 0:
        message = status_messages.get(status, f"unknown status 0x{status:02X}")
        raise RuntimeError(f"USB device rejected command: {message}")
    return response


class UsbSession:
    def __init__(self):
        self.usb_core = None
        self.usb_util = None
        self.dev = None
        self.out_ep = None
        self.in_ep = None
        self.interface_number = None
        self.claimed = False
        self.healthy = True

    def __enter__(self):
        self.usb_core, self.usb_util = load_pyusb()
        self.dev = self.usb_core.find(idVendor=VID, idProduct=PID)
        if self.dev is None:
            raise RuntimeError(f"USB device {VID:04X}:{PID:04X} not found")

        try:
            interface, self.out_ep, self.in_ep = get_endpoints(self.dev, self.usb_util)
            self.interface_number = interface.bInterfaceNumber
            self.usb_util.claim_interface(self.dev, self.interface_number)
            self.claimed = True
        except (RuntimeError, self.usb_core.USBError):
            self.usb_util.dispose_resources(self.dev)
            raise

        return self

    def __exit__(self, exc_type, exc_value, traceback):
        try:
            if self.claimed:
                self.usb_util.release_interface(self.dev, self.interface_number)
                self.claimed = False
        finally:
            self.usb_util.dispose_resources(self.dev)

    def send_command(self, opcode, payload, response_length=2, status_messages=None):
        try:
            return send_command(
                self.dev,
                self.out_ep,
                self.in_ep,
                opcode,
                payload,
                response_length=response_length,
                status_messages=status_messages,
            )
        except (RuntimeError, self.usb_core.USBError):
            self.healthy = False
            raise


def execute_command(
    opcode,
    payload,
    response_length=2,
    status_messages=None,
):
    with UsbSession() as session:
        return session.send_command(
            opcode,
            payload,
            response_length=response_length,
            status_messages=status_messages,
        )


def parse_flash_address(value):
    try:
        address = int(value, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            "must be an integer (decimal or 0x-prefixed)"
        ) from exc

    if not 0 <= address < FLASH_SIZE:
        raise argparse.ArgumentTypeError(f"must be between 0 and 0x{FLASH_SIZE - 1:X}")
    return address


def parse_flash_length(value):
    try:
        length = int(value, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            "must be an integer (decimal or 0x-prefixed)"
        ) from exc

    if not 1 <= length <= FLASH_SIZE:
        raise argparse.ArgumentTypeError(f"must be between 1 and 0x{FLASH_SIZE:X}")
    return length


def parse_flash_program_file(path):
    data = bytearray()
    hex_digits = frozenset("0123456789abcdefABCDEF")
    with Path(path).open("r", encoding="ascii") as source:
        for line in source:
            parts = line.split()
            if len(parts) == 1 and len(parts[0]) == 8:
                byte_values = [
                    parts[0][index : index + 2] for index in range(0, 8, 2)
                ]
            elif len(parts) == 4 and all(len(part) == 2 for part in parts):
                byte_values = parts
            else:
                continue

            if not all(
                all(character in hex_digits for character in value)
                for value in byte_values
            ):
                continue

            data.extend(int(value, 16) for value in byte_values)
            if len(data) > FLASH_SIZE:
                raise ValueError(
                    f"program data exceeds the {FLASH_SIZE}-byte flash capacity"
                )

    if not data:
        raise ValueError("the file contains no valid four-byte hexadecimal lines")
    return bytes(data)


def read_flash(address, length, progress_callback=None):
    if not 0 <= address < FLASH_SIZE or not 1 <= length <= FLASH_SIZE:
        raise ValueError("flash address or length is out of range")
    if address + length > FLASH_SIZE:
        raise ValueError("flash read range extends past the end of the device")

    usb_core, usb_util = load_pyusb()
    dev = usb_core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        raise RuntimeError(f"USB device {VID:04X}:{PID:04X} not found")

    claimed_interface = None
    cs_may_be_asserted = False
    phase = "configuring USB interface"
    failed_phase = None
    operation_error = None
    cleanup_errors = []
    data = bytearray()
    try:
        interface, out_ep, in_ep = get_endpoints(dev, usb_util)
        interface_number = interface.bInterfaceNumber
        usb_util.claim_interface(dev, interface_number)
        claimed_interface = interface_number

        phase = "setting SPI divider (USB opcode 0x12)"
        send_command(dev, out_ep, in_ep, 0x12, bytes((FLASH_SPI_DIVIDER,)))
        phase = "asserting flash CS# (USB opcode 0x11)"
        cs_may_be_asserted = True
        send_command(dev, out_ep, in_ep, 0x11, b"\x01")
        phase = "sending flash wake command 0xAB"
        for tx_byte in (0xAB, 0x00, 0x00, 0x00, 0x00):
            send_command(
                dev,
                out_ep,
                in_ep,
                0x10,
                bytes((tx_byte,)),
                response_length=3,
                status_messages=SPI_STATUS_MESSAGES,
            )
        phase = "releasing CS# after flash wake command"
        send_command(dev, out_ep, in_ep, 0x11, b"\x00")
        cs_may_be_asserted = False

        phase = "asserting CS# for flash fast read"
        cs_may_be_asserted = True
        send_command(dev, out_ep, in_ep, 0x11, b"\x01")
        phase = "sending flash FAST_READ opcode 0x0B"
        for tx_byte in (
            0x0B,
            (address >> 16) & 0xFF,
            (address >> 8) & 0xFF,
            address & 0xFF,
        ):
            send_command(
                dev,
                out_ep,
                in_ep,
                0x10,
                bytes((tx_byte,)),
                response_length=3,
                status_messages=SPI_STATUS_MESSAGES,
            )

        total_read_bytes = length + 1
        for offset in range(total_read_bytes):
            phase = f"reading flash data byte {min(offset, length) + 1}/{length}"
            response = send_command(
                dev,
                out_ep,
                in_ep,
                0x10,
                b"\x00",
                response_length=3,
                status_messages=SPI_STATUS_MESSAGES,
            )
            if offset != 0:
                data.append(response[2])
                completed = offset
                if progress_callback is not None and (
                    completed == length or completed % 4096 == 0
                ):
                    progress_callback(completed, length)
    except (RuntimeError, usb_core.USBError) as exc:
        failed_phase = phase
        operation_error = exc
    finally:
        if cs_may_be_asserted:
            try:
                phase = "releasing flash CS# (USB opcode 0x11)"
                send_command(dev, out_ep, in_ep, 0x11, b"\x00")
            except (RuntimeError, usb_core.USBError) as exc:
                cleanup_errors.append(f"CS# release failed: {exc}")
        if claimed_interface is not None:
            try:
                usb_util.release_interface(dev, claimed_interface)
            except usb_core.USBError as exc:
                cleanup_errors.append(f"USB interface release failed: {exc}")
        try:
            usb_util.dispose_resources(dev)
        except usb_core.USBError as exc:
            cleanup_errors.append(f"USB resource cleanup failed: {exc}")

    if operation_error is not None:
        message = f"Flash read failed while {failed_phase}: {operation_error}"
        if cleanup_errors:
            message += "; " + "; ".join(cleanup_errors)
        raise RuntimeError(message) from operation_error
    if cleanup_errors:
        raise RuntimeError("; ".join(cleanup_errors))

    return bytes(data)


def _run_flash_write(data=None, progress_callback=None, erase=False):
    usb_core, usb_util = load_pyusb()
    dev = usb_core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        raise RuntimeError(f"USB device {VID:04X}:{PID:04X} not found")

    claimed_interface = None
    cs_may_be_asserted = False
    phase = "configuring USB interface"
    failed_phase = None
    operation_error = None
    cleanup_errors = []

    def set_chip_select(asserted):
        nonlocal cs_may_be_asserted
        if asserted:
            cs_may_be_asserted = True
        send_command(dev, out_ep, in_ep, 0x11, bytes((int(asserted),)))
        if not asserted:
            cs_may_be_asserted = False

    def transfer_spi_byte(value):
        response = send_command(
            dev,
            out_ep,
            in_ep,
            0x10,
            bytes((value,)),
            response_length=3,
            status_messages=SPI_STATUS_MESSAGES,
        )
        return response[2]

    def spi_transaction(values):
        set_chip_select(True)
        for value in values:
            transfer_spi_byte(value)
        set_chip_select(False)

    def wait_until_ready():
        while True:
            set_chip_select(True)
            transfer_spi_byte(0x05)
            status = transfer_spi_byte(0x00)
            set_chip_select(False)
            if status & 0x01 == 0:
                return

    try:
        interface, out_ep, in_ep = get_endpoints(dev, usb_util)
        interface_number = interface.bInterfaceNumber
        usb_util.claim_interface(dev, interface_number)
        claimed_interface = interface_number

        phase = "setting SPI divider (USB opcode 0x12)"
        send_command(dev, out_ep, in_ep, 0x12, bytes((FLASH_SPI_DIVIDER,)))
        phase = "waking flash"
        spi_transaction((0xAB, 0x00, 0x00, 0x00, 0x00))

        if erase:
            phase = "enabling flash erase"
            spi_transaction((0x06,))
            phase = "erasing the entire flash"
            spi_transaction((0x60,))
            phase = "waiting for flash erase to finish"
            wait_until_ready()
            if progress_callback is not None:
                progress_callback(1, 1)
        else:
            page_size = 256
            for offset in range(0, len(data), page_size):
                page_data = data[offset : offset + page_size]
                phase = f"enabling page program at address 0x{offset:06X}"
                spi_transaction((0x06,))
                phase = f"programming flash page at address 0x{offset:06X}"
                address_bytes = (
                    (offset >> 16) & 0xFF,
                    (offset >> 8) & 0xFF,
                    offset & 0xFF,
                )
                spi_transaction((0x02, *address_bytes, *page_data))
                phase = f"waiting for flash page at address 0x{offset:06X}"
                wait_until_ready()
                if progress_callback is not None:
                    progress_callback(offset + len(page_data), len(data))

    except (RuntimeError, usb_core.USBError) as exc:
        failed_phase = phase
        operation_error = exc
    finally:
        if cs_may_be_asserted:
            try:
                send_command(dev, out_ep, in_ep, 0x11, b"\x00")
            except (RuntimeError, usb_core.USBError) as exc:
                cleanup_errors.append(f"CS# release failed: {exc}")
        if claimed_interface is not None:
            try:
                usb_util.release_interface(dev, claimed_interface)
            except usb_core.USBError as exc:
                cleanup_errors.append(f"USB interface release failed: {exc}")
        try:
            usb_util.dispose_resources(dev)
        except usb_core.USBError as exc:
            cleanup_errors.append(f"USB resource cleanup failed: {exc}")

    if operation_error is not None:
        operation = "erase" if erase else "program"
        message = f"Flash {operation} failed while {failed_phase}: {operation_error}"
        if cleanup_errors:
            message += "; " + "; ".join(cleanup_errors)
        raise RuntimeError(message) from operation_error
    if cleanup_errors:
        raise RuntimeError("; ".join(cleanup_errors))


def program_flash(data, progress_callback=None):
    if not data:
        raise ValueError("flash program data must not be empty")
    if len(data) > FLASH_SIZE:
        raise ValueError(f"flash program data exceeds {FLASH_SIZE} bytes")
    _run_flash_write(data=data, progress_callback=progress_callback)


def erase_flash(progress_callback=None):
    _run_flash_write(progress_callback=progress_callback, erase=True)


def format_flash_hex_lines(data, address, start, end):
    return "\n".join(
        f"{address + offset:06X}: "
        + " ".join(f"{byte:02X}" for byte in data[offset : offset + 4])
        for offset in range(start, end, 4)
    )


def command_arguments():
    parser = argparse.ArgumentParser(
        description=f"Control the USB LED and SPI flash on {VID:04X}:{PID:04X}."
    )
    commands = parser.add_subparsers(dest="command", required=True)
    on_parser = commands.add_parser(
        "on", help="turn the LED on for a duration, or until turned off"
    )
    on_parser.add_argument(
        "milliseconds",
        nargs="?",
        type=parse_milliseconds,
        help="on-time in milliseconds using a host-side timer; omit to leave it on",
    )
    commands.add_parser("off", help="turn the USB-controlled LED off")
    spi_cs_parser = commands.add_parser("spi-cs", help="assert or release SPI CS#")
    spi_cs_parser.add_argument("action", choices=("assert", "release"))
    spi_transfer_parser = commands.add_parser(
        "spi-transfer", help="transfer one byte over SPI and print the received byte"
    )
    spi_transfer_parser.add_argument("byte", type=parse_byte)
    spi_clock_parser = commands.add_parser(
        "spi-clock",
        help=f"set the SPI half-period divider ({SPI_DIVIDER_MIN}-{SPI_DIVIDER_MAX})",
    )
    spi_clock_parser.add_argument("divider", type=parse_spi_divider)
    commands.add_parser(
        "spi-session",
        help="keep one USB connection open for an interactive SPI session",
    )
    flash_read_parser = commands.add_parser(
        "flash-read", help="read a range from the AT25EU0161A flash to a binary file"
    )
    flash_read_parser.add_argument("address", type=parse_flash_address)
    flash_read_parser.add_argument("length", type=parse_flash_length)
    flash_read_parser.add_argument("output", type=Path)

    args = parser.parse_args()
    if args.command == "flash-read" and args.address + args.length > FLASH_SIZE:
        parser.error(f"flash range ends past the last byte (0x{FLASH_SIZE - 1:X})")
    return args


def parse_byte(value):
    try:
        byte = int(value, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            "must be an integer (decimal or 0x-prefixed)"
        ) from exc

    if not 0 <= byte <= 0xFF:
        raise argparse.ArgumentTypeError("must be between 0 and 255")
    return byte


def parse_spi_divider(value):
    try:
        divider = int(value, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            "must be an integer (decimal or 0x-prefixed)"
        ) from exc

    if not SPI_DIVIDER_MIN <= divider <= SPI_DIVIDER_MAX:
        raise argparse.ArgumentTypeError(
            f"must be between {SPI_DIVIDER_MIN} and {SPI_DIVIDER_MAX}"
        )
    return divider


def run_cli():
    args = command_arguments()

    if args.command == "spi-session":
        run_spi_session()
    elif args.command == "on":
        if args.milliseconds is None:
            execute_command(0x01, b"\x01\x00")
            print("LED on until turned off.")
        else:
            execute_command(0x01, b"\x01\x00")
            try:
                time.sleep(args.milliseconds / 1000)
            finally:
                execute_command(0x02, b"")
            print(f"LED on for {args.milliseconds} ms.")
    elif args.command == "off":
        opcode = 0x02
        payload = b""
        execute_command(opcode, payload)
        print("LED off.")
    elif args.command == "spi-cs":
        payload = b"\x01" if args.action == "assert" else b"\x00"
        execute_command(0x11, payload)
        state = "asserted" if args.action == "assert" else "released"
        print(f"SPI CS# {state}.")
    elif args.command == "spi-clock":
        execute_command(0x12, bytes((args.divider,)))
        print(f"SPI divider set to {args.divider}.")
    elif args.command == "spi-transfer":
        response = execute_command(
            0x10,
            bytes((args.byte,)),
            response_length=3,
            status_messages=SPI_STATUS_MESSAGES,
        )
        print(f"SPI RX: 0x{response[2]:02X}")
    else:

        def report_progress(completed, total):
            print(
                f"\rReading flash: {completed}/{total} bytes",
                end="",
                flush=True,
            )

        data = read_flash(args.address, args.length, report_progress)
        print()
        try:
            args.output.write_bytes(data)
        except OSError as exc:
            raise RuntimeError(
                f"Could not write flash data to {args.output}: {exc}"
            ) from exc
        print(f"Saved {len(data)} bytes to {args.output}.")


def run_spi_session():
    print(
        f"SPI session connected. Commands: clock <{SPI_DIVIDER_MIN}-{SPI_DIVIDER_MAX}>, "
        "cs assert|release,"
    )
    print("xfer <byte>, help, quit.")

    with UsbSession() as session:
        cs_asserted = False
        try:
            while True:
                try:
                    command = input("spi> ").strip().split()
                except EOFError:
                    break
                if not command:
                    continue

                action = command[0].lower()
                if action in ("quit", "exit"):
                    break
                if action == "help":
                    print(
                        f"clock <{SPI_DIVIDER_MIN}-{SPI_DIVIDER_MAX}>  "
                        "Set SPI clock divider"
                    )
                    print("cs assert      Assert flash CS#")
                    print("cs release     Release flash CS#")
                    print("xfer <byte>    Transfer one byte (decimal or 0x-prefixed)")
                    print("quit           End the session")
                    continue

                try:
                    if action == "clock" and len(command) == 2:
                        divider = parse_spi_divider(command[1])
                        session.send_command(0x12, bytes((divider,)))
                        print(f"SPI divider set to {divider}.")
                    elif action == "cs" and len(command) == 2:
                        state = command[1].lower()
                        if state not in ("assert", "release"):
                            raise ValueError("use 'cs assert' or 'cs release'")
                        asserted = state == "assert"
                        session.send_command(0x11, bytes((int(asserted),)))
                        cs_asserted = asserted
                        print(f"SPI CS# {'asserted' if asserted else 'released'}.")
                    elif action == "xfer" and len(command) == 2:
                        tx_byte = parse_byte(command[1])
                        response = session.send_command(
                            0x10,
                            bytes((tx_byte,)),
                            response_length=3,
                            status_messages=SPI_STATUS_MESSAGES,
                        )
                        print(f"SPI RX: 0x{response[2]:02X}")
                    else:
                        print(
                            "Invalid command. Enter 'help' to see available commands."
                        )
                except (ValueError, argparse.ArgumentTypeError) as exc:
                    print(f"Invalid argument: {exc}")
        finally:
            if cs_asserted and session.healthy:
                try:
                    session.send_command(0x11, b"\x00")
                    print("SPI CS# released.")
                except (RuntimeError, session.usb_core.USBError) as exc:
                    print(f"Warning: could not release SPI CS#: {exc}", file=sys.stderr)


def run_gui():
    try:
        import tkinter as tk
        from tkinter import filedialog, messagebox, ttk
    except ModuleNotFoundError as exc:
        if exc.name == "_tkinter" or exc.name == "tkinter":
            raise RuntimeError(
                "Tkinter is unavailable. Install the Tk support for your Python "
                "version, then run this script again."
            ) from exc
        raise

    usb_core, _ = load_pyusb()
    root = tk.Tk()
    root.title("Керування USB LED та SPI Flash")
    root.minsize(760, 420)
    root.columnconfigure(0, weight=1)
    root.rowconfigure(0, weight=1)

    frame = ttk.Frame(root, padding=16)
    frame.grid(row=0, column=0, sticky="nsew")
    frame.columnconfigure(0, weight=0)
    frame.columnconfigure(1, weight=1)
    frame.rowconfigure(1, weight=1)

    ttk.Label(
        frame,
        text=f"USB-пристрій {VID:04X}:{PID:04X}",
        font=("", 15, "bold"),
    ).grid(row=0, column=0, columnspan=2, sticky="w", pady=(0, 14))

    controls = ttk.Frame(frame)
    controls.grid(row=1, column=0, sticky="new", padx=(0, 16))
    controls.columnconfigure(0, weight=1)

    led_frame = ttk.LabelFrame(controls, text="LED", padding=12)
    led_frame.grid(row=0, column=0, sticky="ew")
    led_frame.columnconfigure(1, weight=1)
    duration = tk.StringVar(value="1000")
    always_on = tk.BooleanVar(value=False)
    ttk.Label(led_frame, text="Тривалість (мс, таймер на ПК):").grid(
        row=0, column=0, sticky="w", padx=(0, 12), pady=4
    )
    duration_input = ttk.Spinbox(
        led_frame, from_=1, to=0xFFFE, textvariable=duration, width=12
    )
    duration_input.grid(row=0, column=1, sticky="ew", pady=4)

    def update_duration_state():
        duration_input.configure(state="disabled" if always_on.get() else "normal")

    ttk.Checkbutton(
        led_frame,
        text="Залишити увімкненим",
        variable=always_on,
        command=update_duration_state,
    ).grid(row=1, column=0, columnspan=2, sticky="w", pady=(4, 12))

    led_off_after = None

    def cancel_led_off_timer():
        nonlocal led_off_after
        if led_off_after is not None:
            root.after_cancel(led_off_after)
            led_off_after = None

    def send_from_ui(opcode, payload, success_message):
        status.set("Зв’язок із пристроєм…")
        root.update_idletasks()
        try:
            execute_command(opcode, payload)
        except RuntimeError as exc:
            status.set(f"Помилка: {exc}")
            messagebox.showerror("Помилка USB", str(exc), parent=root)
            return False
        except usb_core.USBError as exc:
            status.set(f"Помилка USB: {exc}")
            messagebox.showerror("Помилка USB", str(exc), parent=root)
            return False
        else:
            status.set(success_message)
            return True

    def turn_on():
        nonlocal led_off_after
        milliseconds = None
        if not always_on.get():
            try:
                milliseconds = parse_milliseconds(duration.get())
            except argparse.ArgumentTypeError as exc:
                messagebox.showerror("Некоректна тривалість", str(exc), parent=root)
                return

        message = (
            "LED увімкнено без обмеження часу."
            if milliseconds is None
            else f"LED увімкнено на {milliseconds} мс (таймер на ПК)."
        )
        if send_from_ui(0x01, b"\x01\x00", message):
            cancel_led_off_timer()
            if milliseconds is not None:
                led_off_after = root.after(milliseconds, turn_off_after_timer)

    def turn_off_after_timer():
        nonlocal led_off_after
        led_off_after = None
        send_from_ui(0x02, b"", "LED вимкнено.")

    def turn_off():
        if send_from_ui(0x02, b"", "LED вимкнено."):
            cancel_led_off_timer()

    ttk.Button(led_frame, text="Увімкнути", command=turn_on).grid(
        row=2, column=0, sticky="ew", padx=(0, 6)
    )
    ttk.Button(
        led_frame,
        text="Вимкнути",
        command=turn_off,
    ).grid(row=2, column=1, sticky="ew", padx=(6, 0))

    flash_frame = ttk.LabelFrame(controls, text="SPI Flash", padding=12)
    flash_frame.grid(row=1, column=0, sticky="ew", pady=(12, 0))
    flash_frame.columnconfigure(1, weight=1)
    flash_address = tk.StringVar(value="0x000000")
    flash_length = tk.StringVar(value="256")
    program_file = tk.StringVar()
    ttk.Label(flash_frame, text="Початкова адреса:").grid(
        row=0, column=0, sticky="w", padx=(0, 12), pady=4
    )
    ttk.Entry(flash_frame, textvariable=flash_address, width=14).grid(
        row=0, column=1, sticky="ew", pady=4
    )
    ttk.Label(flash_frame, text="Розмір (байт):").grid(
        row=1, column=0, sticky="w", padx=(0, 12), pady=4
    )
    ttk.Entry(flash_frame, textvariable=flash_length, width=14).grid(
        row=1, column=1, sticky="ew", pady=4
    )
    ttk.Label(flash_frame, text="Файл програмування:").grid(
        row=2, column=0, sticky="w", padx=(0, 12), pady=4
    )
    ttk.Entry(flash_frame, textvariable=program_file).grid(
        row=2, column=1, sticky="ew", pady=4
    )

    log_frame = ttk.LabelFrame(frame, text="Дані Flash (hex)", padding=8)
    log_frame.grid(row=1, column=1, sticky="nsew")
    log_frame.columnconfigure(0, weight=1)
    log_frame.rowconfigure(0, weight=1)
    flash_log = tk.Text(log_frame, width=64, height=24, wrap="none", state="disabled")
    flash_log.grid(row=0, column=0, sticky="nsew")
    log_scrollbar = ttk.Scrollbar(log_frame, orient="vertical", command=flash_log.yview)
    log_scrollbar.grid(row=0, column=1, sticky="ns")
    flash_log.configure(yscrollcommand=log_scrollbar.set)

    status = tk.StringVar(value="Готово до керування.")

    def finish_flash_read(data, address):
        flash_log.configure(state="normal")
        flash_log.delete("1.0", "end")

        def append_hex_lines(offset):
            end = min(offset + 4096, len(data))
            flash_log.insert(
                "end", format_flash_hex_lines(data, address, offset, end) + "\n"
            )
            if end < len(data):
                root.after(1, append_hex_lines, end)
            else:
                flash_log.configure(state="disabled")
                flash_log.see("1.0")
                for button in flash_action_buttons:
                    button.configure(state="normal")
                status.set(f"Зчитано {len(data)} байт із адреси 0x{address:06X}.")

        append_hex_lines(0)

    def fail_flash_read(error):
        for button in flash_action_buttons:
            button.configure(state="normal")
        status.set(f"Помилка читання Flash: {error}")
        messagebox.showerror("Помилка читання Flash", error, parent=root)

    def choose_program_file():
        selected_file = filedialog.askopenfilename(
            parent=root,
            title="Виберіть файл для програмування Flash",
            filetypes=(("HEX files", "*.hex *.txt"), ("All files", "*")),
        )
        if selected_file:
            program_file.set(selected_file)

    def start_flash_write(data=None, erase=False):
        action = "стирання" if erase else "програмування"
        total = 1 if erase else len(data)
        label = "Стирання Flash" if erase else "Програмування Flash"
        status.set(f"{label}: 0/{total}…")
        for button in flash_action_buttons:
            button.configure(state="disabled")

        def finish_flash_write():
            for button in flash_action_buttons:
                button.configure(state="normal")
            if erase:
                status.set("Flash повністю стерто.")
            else:
                status.set(f"Запрограмовано {len(data)} байт із файлу.")

        def fail_flash_write(error):
            for button in flash_action_buttons:
                button.configure(state="normal")
            status.set(f"Помилка {action} Flash: {error}")
            messagebox.showerror(
                f"Помилка {action} Flash", error, parent=root
            )

        def write_in_background():
            def report_progress(completed, progress_total):
                label = "Стирання" if erase else "Програмування"
                root.after(
                    0,
                    status.set,
                    f"{label} Flash: {completed}/{progress_total} байт…",
                )

            try:
                if erase:
                    erase_flash(report_progress)
                else:
                    program_flash(data, report_progress)
            except (RuntimeError, usb_core.USBError) as exc:
                root.after(0, fail_flash_write, str(exc))
            else:
                root.after(0, finish_flash_write)

        threading.Thread(target=write_in_background, daemon=True).start()

    def program_from_file():
        selected_file = program_file.get().strip()
        if not selected_file:
            choose_program_file()
            selected_file = program_file.get().strip()
        if not selected_file:
            return

        try:
            data = parse_flash_program_file(selected_file)
        except (OSError, UnicodeError, ValueError) as exc:
            messagebox.showerror(
                "Помилка файлу програмування", str(exc), parent=root
            )
            return
        start_flash_write(data=data)

    def erase_entire_flash():
        confirmed = messagebox.askyesno(
            "Підтвердження стирання",
            "Буде стерто всю пам’ять Flash. Продовжити?",
            icon="warning",
            parent=root,
        )
        if confirmed:
            start_flash_write(erase=True)

    def read_from_flash():
        try:
            address = parse_flash_address(flash_address.get())
            length = parse_flash_length(flash_length.get())
            if address + length > FLASH_SIZE:
                raise ValueError(
                    f"Діапазон виходить за межі Flash (0x{FLASH_SIZE - 1:X})."
                )
        except (argparse.ArgumentTypeError, ValueError) as exc:
            messagebox.showerror("Некоректний діапазон", str(exc), parent=root)
            return

        for button in flash_action_buttons:
            button.configure(state="disabled")
        flash_log.configure(state="normal")
        flash_log.delete("1.0", "end")
        flash_log.configure(state="disabled")
        status.set(f"Читання Flash: 0/{length} байт…")

        def read_in_background():
            def report_progress(completed, total):
                root.after(0, status.set, f"Читання Flash: {completed}/{total} байт…")

            try:
                data = read_flash(address, length, report_progress)
            except (RuntimeError, usb_core.USBError) as exc:
                root.after(0, fail_flash_read, str(exc))
            else:
                root.after(0, finish_flash_read, data, address)

        threading.Thread(target=read_in_background, daemon=True).start()

    browse_button = ttk.Button(
        flash_frame, text="Відкрити файл…", command=choose_program_file
    )
    browse_button.grid(row=3, column=0, sticky="ew", pady=(10, 0), padx=(0, 6))
    read_button = ttk.Button(flash_frame, text="Зчитати", command=read_from_flash)
    read_button.grid(row=3, column=1, sticky="ew", pady=(10, 0), padx=(6, 0))
    program_button = ttk.Button(
        flash_frame, text="Програмувати", command=program_from_file
    )
    program_button.grid(row=4, column=0, sticky="ew", pady=(6, 0), padx=(0, 6))
    erase_button = ttk.Button(
        flash_frame, text="Стерти всю Flash", command=erase_entire_flash
    )
    erase_button.grid(row=4, column=1, sticky="ew", pady=(6, 0), padx=(6, 0))
    flash_action_buttons = (
        browse_button,
        read_button,
        program_button,
        erase_button,
    )

    ttk.Label(frame, textvariable=status, wraplength=700, justify="left").grid(
        row=2, column=0, columnspan=2, sticky="w", pady=(12, 0)
    )

    root.mainloop()


if __name__ == "__main__":
    try:
        if len(sys.argv) == 1:
            run_gui()
        else:
            run_cli()
    except RuntimeError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
