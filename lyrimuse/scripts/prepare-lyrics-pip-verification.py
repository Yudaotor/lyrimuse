#!/usr/bin/env python3
"""Package an already-built Debug app with fixture playback and a separate identity.

Run `swift build --product lyrimuse` in lyrimuse first, then this script with
--output <artifact-directory>. It neither installs nor launches the application.
"""
import argparse
import pathlib
import plistlib
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=pathlib.Path, required=True)
args = parser.parse_args()
package = pathlib.Path(__file__).resolve().parents[1]
products = pathlib.Path(subprocess.check_output(
    ["swift", "build", "--package-path", str(package), "--show-bin-path"], text=True).strip())
output = args.output.resolve()
app = output / "Lyrimuse PiP Verification.app"
contents = app / "Contents"
for folder in ("MacOS", "Resources", "Frameworks"):
    (contents / folder).mkdir(parents=True, exist_ok=True)
binary = contents / "MacOS" / "lyrimuse"
shutil.copy2(products / "lyrimuse", binary)
for resource in products.glob("*.bundle"):
    shutil.copytree(resource, contents / "Resources" / resource.name, dirs_exist_ok=True)
for resource in (package / "Sources/lyrimuse/Resources").glob("*.lproj"):
    shutil.copytree(resource, contents / "Resources" / resource.name, dirs_exist_ok=True)
framework = contents / "Frameworks/Sparkle.framework"
if framework.exists():
    shutil.rmtree(framework)
shutil.copytree(products / "Sparkle.framework", framework, symlinks=True)
with (contents / "Info.plist").open("wb") as file:
    plistlib.dump({
        "CFBundleIdentifier": "me.yudaotor.lyrimuse.pip-verification",
        "CFBundleName": "Lyrimuse PiP Verification",
        "CFBundleExecutable": "lyrimuse",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
        "LyricsPiPVerificationLog": str(output / "ui-verification.log"),
    }, file)
subprocess.run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(binary)], check=True)
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
print(app)
