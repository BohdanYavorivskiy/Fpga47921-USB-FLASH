# USB LED Control

USB LED controller for the device with VID:PID `1209:0001`.

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
