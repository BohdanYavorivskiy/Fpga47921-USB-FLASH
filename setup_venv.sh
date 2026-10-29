#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VENV_DIR="$SCRIPT_DIR/.venv"
REQUIREMENTS_FILE="$SCRIPT_DIR/requirements.txt"
PYTHON=${PYTHON:-python3}

if ! command -v "$PYTHON" >/dev/null 2>&1; then
    printf 'Error: Python interpreter "%s" was not found.\n' "$PYTHON" >&2
    printf 'Install Python 3 or set PYTHON to its executable path.\n' >&2
    exit 1
fi

if [ ! -f "$REQUIREMENTS_FILE" ]; then
    printf 'Error: requirements file not found: %s\n' "$REQUIREMENTS_FILE" >&2
    exit 1
fi

printf 'Creating/updating virtual environment at %s\n' "$VENV_DIR"
"$PYTHON" -m venv "$VENV_DIR"
"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/python" -m pip install -r "$REQUIREMENTS_FILE"

if ! "$VENV_DIR/bin/python" -c 'import tkinter' >/dev/null 2>&1; then
    PYTHON_VERSION=$("$VENV_DIR/bin/python" -c \
        'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    printf 'Error: Tkinter is unavailable; the graphical interface will not run.\n' >&2
    if [ "$(uname -s)" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
        printf 'Install it with: brew install python-tk@%s\n' "$PYTHON_VERSION" >&2
    else
        printf 'Install the Tk package for the selected Python interpreter, then rerun this script.\n' >&2
    fi
    exit 1
fi

printf '\nSetup complete.\n'
printf 'Launch the graphical interface with:\n  %s/bin/python %s/usb.py\n' "$VENV_DIR" "$SCRIPT_DIR"
