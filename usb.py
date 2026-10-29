import argparse
import os
from pathlib import Path
import sys


VID = 0x1209
PID = 0x0001
EP_OUT = 0x01
EP_IN = 0x81
INTERFACE = 0

STATUS_MESSAGES = {
    0x00: "success",
    0x01: "invalid command length",
    0x02: "unknown command",
}


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


def send_command(dev, out_ep, in_ep, opcode, payload):
    command = bytes((opcode,)) + payload
    written = dev.write(out_ep, command, timeout=1000)
    if written != len(command):
        raise RuntimeError(
            f"USB command was only partially sent ({written}/{len(command)} bytes)"
        )

    response = bytes(dev.read(in_ep, 2, timeout=1000))
    if len(response) != 2:
        raise RuntimeError(
            f"Expected a 2-byte USB response, received {len(response)} bytes"
        )

    response_opcode, status = response
    if response_opcode != opcode:
        raise RuntimeError(
            f"USB response opcode 0x{response_opcode:02X} does not match "
            f"command 0x{opcode:02X}"
        )
    if status != 0:
        message = STATUS_MESSAGES.get(status, f"unknown status 0x{status:02X}")
        raise RuntimeError(f"USB device rejected command: {message}")


def execute_command(opcode, payload):
    usb_core, usb_util = load_pyusb()
    dev = usb_core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        raise RuntimeError(f"USB device {VID:04X}:{PID:04X} not found")

    claimed_interface = None
    try:
        interface, out_ep, in_ep = get_endpoints(dev, usb_util)
        interface_number = interface.bInterfaceNumber
        usb_util.claim_interface(dev, interface_number)
        claimed_interface = interface_number
        send_command(dev, out_ep, in_ep, opcode, payload)
    finally:
        try:
            if claimed_interface is not None:
                usb_util.release_interface(dev, claimed_interface)
        finally:
            usb_util.dispose_resources(dev)


def command_arguments():
    parser = argparse.ArgumentParser(
        description=f"Control the LED on USB device {VID:04X}:{PID:04X}."
    )
    commands = parser.add_subparsers(dest="command", required=True)
    on_parser = commands.add_parser(
        "on", help="turn the LED on for a duration, or forever"
    )
    on_parser.add_argument(
        "milliseconds",
        nargs="?",
        type=parse_milliseconds,
        help="on-time in milliseconds (1-65534); omit to leave the LED on",
    )
    commands.add_parser("off", help="turn the USB-controlled LED off")
    return parser.parse_args()


def run_cli():
    args = command_arguments()

    if args.command == "on":
        opcode = 0x01
        milliseconds = (
            0xFFFF if args.milliseconds is None else args.milliseconds
        )
        payload = milliseconds.to_bytes(2, byteorder="little")
        description = (
            "on indefinitely"
            if milliseconds == 0xFFFF
            else f"on for {milliseconds} ms"
        )
    else:
        opcode = 0x02
        payload = b""
        description = "off"

    execute_command(opcode, payload)
    print(f"LED {description}.")


def run_gui():
    try:
        import tkinter as tk
        from tkinter import messagebox, ttk
    except ModuleNotFoundError as exc:
        if exc.name == "_tkinter" or exc.name == "tkinter":
            raise RuntimeError(
                "Tkinter is unavailable. Install the Tk support for your Python "
                "version, then run this script again."
            ) from exc
        raise

    usb_core, _ = load_pyusb()
    root = tk.Tk()
    root.title("Керування USB LED")
    root.resizable(False, False)

    frame = ttk.Frame(root, padding=20)
    frame.grid(sticky="nsew")
    frame.columnconfigure(0, weight=1)

    ttk.Label(
        frame,
        text=f"USB-пристрій {VID:04X}:{PID:04X}",
        font=("", 15, "bold"),
    ).grid(row=0, column=0, columnspan=2, sticky="w", pady=(0, 14))

    duration = tk.StringVar(value="1000")
    always_on = tk.BooleanVar(value=False)
    ttk.Label(frame, text="Тривалість (мс):").grid(
        row=1, column=0, sticky="w", padx=(0, 12), pady=4
    )
    duration_input = ttk.Spinbox(
        frame, from_=1, to=0xFFFE, textvariable=duration, width=12
    )
    duration_input.grid(row=1, column=1, sticky="ew", pady=4)

    def update_duration_state():
        duration_input.configure(state="disabled" if always_on.get() else "normal")

    ttk.Checkbutton(
        frame,
        text="Залишити увімкненим",
        variable=always_on,
        command=update_duration_state,
    ).grid(row=2, column=0, columnspan=2, sticky="w", pady=(4, 12))

    status = tk.StringVar(value="Готово до керування.")
    status_label = ttk.Label(
        frame, textvariable=status, wraplength=320, justify="left"
    )
    status_label.grid(row=4, column=0, columnspan=2, sticky="w", pady=(14, 0))

    def send_from_ui(opcode, payload, success_message):
        status.set("Зв’язок із пристроєм…")
        root.update_idletasks()
        try:
            execute_command(opcode, payload)
        except RuntimeError as exc:
            status.set(f"Помилка: {exc}")
            messagebox.showerror("Помилка USB", str(exc), parent=root)
        except usb_core.USBError as exc:
            status.set(f"Помилка USB: {exc}")
            messagebox.showerror("Помилка USB", str(exc), parent=root)
        else:
            status.set(success_message)

    def turn_on():
        if always_on.get():
            milliseconds = 0xFFFF
        else:
            try:
                milliseconds = parse_milliseconds(duration.get())
            except argparse.ArgumentTypeError as exc:
                messagebox.showerror("Некоректна тривалість", str(exc), parent=root)
                return

        payload = milliseconds.to_bytes(2, byteorder="little")
        message = (
            "LED увімкнено без обмеження часу."
            if milliseconds == 0xFFFF
            else f"LED увімкнено на {milliseconds} мс."
        )
        send_from_ui(0x01, payload, message)

    ttk.Button(frame, text="Увімкнути", command=turn_on).grid(
        row=3, column=0, sticky="ew", padx=(0, 6)
    )
    ttk.Button(
        frame,
        text="Вимкнути",
        command=lambda: send_from_ui(0x02, b"", "LED вимкнено."),
    ).grid(row=3, column=1, sticky="ew", padx=(6, 0))

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
