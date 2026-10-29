import runpy
from pathlib import Path
import sys


if getattr(sys, "frozen", False):
    app_root = Path(getattr(sys, "_MEIPASS"))
else:
    app_root = Path(__file__).resolve().parent.parent

runpy.run_path(str(app_root / "usb.py"), run_name="__main__")
