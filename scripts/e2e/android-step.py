#!/usr/bin/env python3
# Copyright Elastic Technologies Inc. and/or licensed to
# Elastic Technologies Inc. under one or more contributor license
# agreements. See the NOTICE file distributed with this work for
# additional information regarding copyright ownership.
# Elastic Technologies Inc. licenses this file to you under the Apache
# License, Version 2.0 (the "License"); you may not use this file except
# in compliance with the License. You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Drive the installed release app through the verifier's UI steps."""

import os
from pathlib import Path
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET


ADB = ["adb"]
if os.environ.get("E2E_DEVICE_ID"):
    ADB += ["-s", os.environ["E2E_DEVICE_ID"]]
ARTIFACTS = Path(os.environ.get("E2E_ARTIFACT_DIR", "build/e2e"))
ARTIFACTS.mkdir(parents=True, exist_ok=True)


def node_for(*values):
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        subprocess.run(
            ADB + ["shell", "uiautomator", "dump", "/sdcard/window.xml"],
            check=True, stdout=subprocess.DEVNULL,
        )
        xml = subprocess.check_output(ADB + ["exec-out", "cat", "/sdcard/window.xml"])
        (ARTIFACTS / "android-ui.xml").write_bytes(xml)
        try:
            nodes = ET.fromstring(xml).iter("node")
            for node in nodes:
                if any(node.get(key) in values for key in ("resource-id", "text", "content-desc")):
                    return node
        except ET.ParseError:
            pass
        time.sleep(1)
    raise RuntimeError(f"Timed out waiting for UI target: {values}")


def tap(*values):
    bounds = node_for(*values).get("bounds", "")
    match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
    if not match:
        raise RuntimeError(f"Invalid target bounds: {bounds}")
    left, top, right, bottom = map(int, match.groups())
    subprocess.run(
        ADB + ["shell", "input", "tap", str((left + right) // 2), str((top + bottom) // 2)],
        check=True,
    )


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("berlin", "new-york", "crash"):
        raise SystemExit("Usage: android-step.py <berlin|new-york|crash>")
    step = sys.argv[1]
    if step == "berlin":
        tap("Berlin")
        tap("fetch-forecast-button", "Fetch forecast")
        node_for("Weather data by Open-Meteo.com")
    elif step == "new-york":
        tap("forecast-back-button", "Return to city picker", "Back")
        tap("New York", "New York Intentional error")
        tap("fetch-forecast-button", "Fetch forecast")
        node_for("retry-forecast-button", "Retry forecast request", "Retry request")
    else:
        tap("error-back-button", "Return to city picker", "Try another city")
        tap("crash-button", "Crash the app", "Crash")


if __name__ == "__main__":
    main()
