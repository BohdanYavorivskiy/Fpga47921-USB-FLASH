# USB LED and SPI Flash Control

This project provides a USB Full-Speed device (VID:PID `1209:0001`) with a
vendor-specific bulk interface. A PC can control the on-board LED and use the
FPGA as an SPI master for an external flash device.

## Using the device from a PC

### Setup

Create the project's Python environment and install its dependencies:

```bash
./setup_venv.sh
```

The host utility is [usb.py](./usb.py). It uses PyUSB to find the device,
select USB configuration 1, claim interface 0, send a command, and read its
response. Connect the FPGA board over USB and make sure the operating system
allows the application to access it. On systems that require a USB backend or
device permissions, install/configure the appropriate backend and permissions.

You can launch the LED GUI with:

```bash
.venv/bin/python usb.py
```

The GUI includes address and size fields for reading flash. Click **Зчитати**
to show the returned bytes in the hex log beside the controls, four bytes per
line.

Or control the LED from the command line:

```bash
.venv/bin/python usb.py on 1000  # On for 1000 ms
.venv/bin/python usb.py on       # On indefinitely
.venv/bin/python usb.py off      # Off
```

### USB interface and command protocol

The device exposes configuration 1, interface 0, with vendor-specific bulk
endpoints:

| Endpoint | Address | Direction |
| --- | --- | --- |
| EP1 OUT | `0x01` | PC to FPGA |
| EP1 IN | `0x81` | FPGA to PC |

Each OUT command is one byte of opcode followed by its payload. The host then
reads the corresponding response from EP1 IN. Multi-byte values are sent
least-significant byte first where specified below.

LED commands:

| Opcode | OUT payload | IN response | Meaning |
| --- | --- | --- | --- |
| `0x01` | 2-byte duration in ms, little-endian | `{0x01, status}` | Set LED duration; `0xFFFF` means indefinitely, `0` turns it off |
| `0x02` | Empty | `{0x02, status}` | Turn the LED off |

General command status values are `0` for success, `1` for invalid command
length/value, and `2` for an unknown opcode. SPI transfer commands have
additional status values documented below.

For applications that need direct control, install PyUSB in the environment
and use the same endpoint protocol. For example, the following sends an LED
OFF command:

```python
import usb.core
import usb.util

dev = usb.core.find(idVendor=0x1209, idProduct=0x0001)
if dev is None:
    raise RuntimeError("USB device 1209:0001 not found")

dev.set_configuration(1)
interface = dev.get_active_configuration()[(0, 0)]
usb.util.claim_interface(dev, interface.bInterfaceNumber)
try:
    written = dev.write(0x01, bytes([0x02]), timeout=1000)
    if written != 1:
        raise RuntimeError(f"Short USB write: {written}/1 byte")
    response = bytes(dev.read(0x81, 2, timeout=1000))
    if response != bytes([0x02, 0x00]):
        raise RuntimeError(f"Unexpected device response: {response.hex()}")
finally:
    usb.util.release_interface(dev, interface.bInterfaceNumber)
    usb.util.dispose_resources(dev)
```

## SPI flash from the PC

### Wiring and SPI behavior

Connect the flash device to these FPGA GPIOs:

| FPGA GPIO | SPI signal | Flash signal |
| --- | --- | --- |
| GPIO0 | CS# | Chip Select |
| GPIO1 | SCK | Clock |
| GPIO2 | MISO | SO |
| GPIO3 | MOSI | SI |

The FPGA operates as an SPI Mode 0 master: SCK is low while idle, data is
transferred in 8-bit, MSB-first frames, MOSI changes on falling SCK edges, and
MISO is sampled on rising SCK edges. The PC controls CS# explicitly. It stays
asserted across byte transfers until the host releases it, and can only change
between bytes. The FPGA handles byte shifting and timing only; flash opcodes,
addresses, data sequencing, and busy polling are the host application's
responsibility.

### SPI USB commands

The SPI master is controlled using the same EP1 bulk endpoints described above:

| Opcode | OUT payload | IN response | Meaning |
| --- | --- | --- | --- |
| `0x10` | One TX byte | `{0x10, status, RX byte}` | Transfer one byte, MSB first |
| `0x11` | One byte: `0` or `1` | `{0x11, status}` | `1` asserts CS#; `0` releases CS# |
| `0x12` | One divider byte, `1..255` | `{0x12, status}` | Configure the SCK half-period divider |
| `0x33` | Empty | `{0x33, 0x00, 0x5A}` | USB IN-path diagnostic; no SPI activity |

For opcode `0x10`, status `0` means the transfer completed and the third
response byte contains the received MISO byte. Status `1` means the SPI master
was busy, `3` means an invalid transfer length, and `4` means CS# was not
asserted. CS and divider commands use the general status values: `0` success,
`1` invalid payload length/value, and `2` unknown opcode.

The SPI divider sets SCK to `f_clk / (2 * divider)`. The current design uses
the 48 MHz USB clock, so its maximum SCK is 24 MHz (divider `1`). Although the
SPI master can support at least 50 MHz with a sufficiently fast clock, this
build does not provide a separate faster SPI clock.

### Persistent command-line SPI session

Use `spi-session` to keep one process, one USB device handle, and interface 0
claimed while sending a sequence of SPI commands. Do not run `spi-cs` and
`spi-transfer` as separate processes when CS# must stay asserted or when
continuing an SPI transaction:

```text
$ .venv/bin/python usb.py spi-session
SPI session connected. Commands: clock <1-255>, cs assert|release,
xfer <byte>, help, quit.
spi> clock 1
SPI divider set to 1.
spi> cs assert
SPI CS# asserted.
spi> xfer 0x9F
SPI RX: 0xEF
spi> debug
USB IN debug check passed: 0x5A.
spi> cs release
SPI CS# released.
spi> quit
```

Each `xfer` returns the byte received from MISO. Keep the session open and CS#
asserted between bytes that belong to one flash command. On `quit` or end of
input, the utility releases CS# if it asserted it, then releases the USB
interface and closes the device handle. Use the flash data sheet to choose
command bytes and any required address, timing, or polling sequence.
Use `debug` immediately after another command to check EP1 IN independently of
the SPI engine; a successful response must contain the payload byte `0x5A`.

The one-shot `spi-clock`, `spi-cs`, and `spi-transfer` commands are available
for isolated operations. Each invocation opens and closes its own USB session;
they are not suitable for maintaining CS# across multiple invocations.

### Reading the AT25EU0161A flash

`flash-read` reads a byte range using the same wake and Fast Read sequence as
`GcdbCardFlashOperations::readFlash` and saves the bytes to a binary file:

```bash
.venv/bin/python usb.py flash-read 0x000000 0x200000 flash.bin
```

The address and length may be decimal or `0x`-prefixed. The AT25EU0161A has
2 MiB of memory, so a read must stay within addresses `0x000000` through
`0x1FFFFF`. The host sets divider `3`, asserts CS#, sends the wake command
`0xAB` plus four zero bytes, then releases CS#. It then asserts CS# again,
sends Fast Read opcode `0x0B` and the 24-bit big-endian address, and clocks
`length + 1` zero bytes while keeping CS# low. The first received byte is the
Fast Read dummy byte and is discarded; the remaining bytes are returned. CS#
is released after the read, including when a transfer fails.

The USB protocol transfers one SPI byte per USB command, so reading large
ranges (especially the entire flash) can take a long time. Progress is shown
while data is being read. The flash must not be busy with a program or erase
operation; the datasheet specifies that a read command issued during a write
cycle is ignored.

### Programming and erasing the flash

The GUI can open a HEX or text file and program its valid data starting at
address `0x000000`. Each data line must contain exactly four hexadecimal bytes,
either separated by spaces (for example `01 02 03 FF`) or written together
(`010203FF`). Other lines are ignored. Data is programmed in 256-byte pages
using Write Enable (`0x06`) followed by Page Program (`0x02`); the host polls
the status register until each page is ready. Programming does not erase the
flash first, so erase the device beforehand when existing contents need to be
replaced.

The GUI's **Стерти всю Flash** action requires confirmation and performs a
full-chip erase using Write Enable (`0x06`) and Chip Erase (`0x60`), then polls
the status register until the operation completes. Both operations cover the
entire input file or flash device respectively, and can take time over the
one-byte-per-USB-command SPI protocol.

### Sending SPI commands directly with PyUSB

An application that sends several SPI bytes can keep the USB interface claimed
while operating the SPI bus. The essential transaction is to write one command
packet to EP1 OUT and then read the specified response length from EP1 IN:

```python
def send_command(dev, opcode, payload, response_length):
    command = bytes([opcode]) + payload
    written = dev.write(0x01, command, timeout=1000)
    if written != len(command):
        raise RuntimeError(f"Short USB write: {written}/{len(command)} bytes")
    response = bytes(dev.read(0x81, response_length, timeout=1000))
    if len(response) != response_length or response[0] != opcode:
        raise RuntimeError(f"Unexpected USB response: {response.hex()}")
    if response[1] != 0:
        raise RuntimeError(f"Device returned status {response[1]}")
    return response

# After finding the device, setting configuration 1, and claiming interface 0:
send_command(dev, 0x12, bytes([1]), 2)         # Divider = 1 (24 MHz SCK)
send_command(dev, 0x11, bytes([1]), 2)         # Assert CS#
response = send_command(dev, 0x10, bytes([0x9F]), 3)
manufacturer_id = response[2]                  # First byte shifted in from MISO
send_command(dev, 0x11, bytes([0]), 2)         # Release CS#
```

Do not release CS# between bytes that belong to the same flash command. Check
the flash data sheet for the correct opcode, number of response bytes, and
whether CS# must remain asserted for the whole transaction.

## Build a macOS app

With the dependencies and Tk support installed, run:

```bash
cd packaging
../.venv/bin/python -m PyInstaller --noconfirm --clean --windowed \
  --name "USB LED Control" \
  --osx-bundle-identifier com.bohdanyavorivskiy.usbledcontrol \
  --distpath ../dist \
  --workpath ../build/pyinstaller \
  --specpath . \
  --add-data ../usb.py:. \
  --hidden-import usb.core \
  --hidden-import usb.util \
  --hidden-import tkinter \
  --hidden-import tkinter.filedialog \
  --hidden-import tkinter.ttk \
  --hidden-import tkinter.messagebox \
  launcher.py
```

The app bundle is created at `../dist/USB LED Control.app` (the repository's
`dist` directory). This builds for the architecture and Python version of the
machine doing the build; it is not code-signed or notarized.
