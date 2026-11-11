# USB LED Control

USB LED controller for the device with VID:PID `1209:0001`.

## FPGA design

The USB device is implemented in the ForgeFPGA project
`usb-to-flash/usb-to-flash.ffpga` (sources in `usb-to-flash/ffpga/src`).
It is a USB Full-Speed device clocked at 48 MHz (PLL0 from the 50 MHz
oscillator). EP0 handles standard control requests; EP1 is a vendor bulk
endpoint carrying the LED commands.

### Recent changes

- **Placed entirely in TILE00.** The design fits in a single EFLX-1K tile
  (127 of 140 CLBs). The constraint file
  `usb-to-flash/ffpga/placement-constraints/tile00.pdc` pins all logic to
  `chip_tile_x=0, chip_tile_y=0` (cells 0-31 in both axes).
- **Area reduced (147 -> 127 CLBs).**
  - `btn_led` no longer has private 19/23-bit counters. It uses the 1 ms tick
    exported by `led_ctrl` (`tick_ms`), so the counters are 4 and 8 bits wide.
    Timing is unchanged: about 11 ms debounce and 175 ms per LED phase.
  - `usb_dev` drops duplicate registers (`c_op`/`c_l` were copies of
    `tb1`/`tb2`) and stores only the setup-packet bits that are decoded.
    USB behaviour is unchanged.
- **Power-up blink.** After reset is released (PLL locked) the LED blinks
  three times, confirming the bitstream is loaded. This is controlled by the
  `BOOT_BLINKS` parameter of `btn_led` (`0` disables it). Pressing the button
  still blinks twice.
- **`btn_led` interface changed.** New input `tick`; parameters are now
  `DEB_BITS`, `DEB_INIT`, `PH_BITS`, `PH_INIT`, `BOOT_BLINKS`. `led_ctrl` has a
  new output `tick_ms`.

### Results (synthesis + place and route)

| Metric | Before | After |
|---|---|---|
| CLBs | 147 | 127 (tile limit 140) |
| LUT5 | 666 | 619 |
| Flip-flops | 396 | 355 |
| Timing at 48 MHz (WNS) | +2.9 ns | +4.9 ns |

PnR finishes with 0 errors and 3 warnings. Two concern IOB flip-flop packing
(`led`, `usb_dp_oe`); the third says `i_clk` is fed without a CLKBUF, which is
intended (`clkbuf_inhibit`).

### Simulation

RTL testbenches are in `usb-to-flash/ffpga/sim`:

```bash
cd usb-to-flash/ffpga/sim
iverilog -g2005 -o /tmp/blink.vvp tb_blink_tb.vt ../src/*.v && vvp /tmp/blink.vvp
iverilog -g2005 -o /tmp/usb.vvp tb_usb_tb.vt ../src/*.v && vvp /tmp/usb.vvp
```

Both print `PASS`. `tb_usb_tb` disables the power-up blinks with a `defparam`.
Full-chip simulation and on-hardware testing have not been run.

## Run

Set up the project's virtual environment and install dependencies:

```bash
./setup_venv.sh
```

The script checks that Tkinter is available. If it is missing, it prints the
platform-specific installation guidance. On macOS with Homebrew Python, it
suggests the matching `python-tk` package.

Launch the graphical interface:

```bash
.venv/bin/python usb.py
```

The window lets you set the LED duration in milliseconds, leave it on
indefinitely, or turn it off. CLI operation is also available:

```bash
.venv/bin/python usb.py on 1000
.venv/bin/python usb.py on
.venv/bin/python usb.py off
```

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
  --hidden-import tkinter.ttk \
  --hidden-import tkinter.messagebox \
  launcher.py
```

The app bundle is created at `../dist/USB LED Control.app` (the repository's
`dist` directory). This builds for the architecture and Python version of the
machine doing the build; it is not code-signed or notarized.
