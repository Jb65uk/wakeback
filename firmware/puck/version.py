# Stamps the firmware with its version (WB_FW_VERSION, shown in the app and on the serial monitor).
#   CI sets the WB_FW_VERSION environment variable to the release number (1.0.N).
#   A build on your own PC gets "dev-<commit>", so the app can tell it isn't a release and never
#   mistakes it for an old one.
Import("env")  # noqa: F821  (PlatformIO provides this)
import os
import subprocess

version = os.environ.get("WB_FW_VERSION", "").strip()
if not version:
    try:
        commit = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=env["PROJECT_DIR"],  # noqa: F821
                                         stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        commit = "local"
    version = "dev-" + commit
print("WakeBack firmware version: " + version)
env.Append(CPPDEFINES=[("WB_FW_VERSION", env.StringifyMacro(version))])  # noqa: F821
