#!/usr/bin/env python3
"""Package a private-sandbox IPA with temporary self-signed build metadata."""
from pathlib import Path
import datetime
import hashlib
import json
import os
import plistlib
import secrets
import shutil
import subprocess
import tempfile
import uuid
import zipfile

root = Path(__file__).resolve().parents[1]
source = root / "build/Release/Build/Products/Release-iphoneos/Retools.app"
destination = root / "Artifacts/Retools-0.1.0-sandbox.ipa"
tool = root / "build/HostTools/reference-signer"
openssl = Path("/opt/homebrew/opt/openssl@3")
os.umask(0o077)

def run(args):
    result = subprocess.run([str(a) for a in args], capture_output=True)
    if result.returncode:
        raise RuntimeError(f"{Path(args[0]).name} failed ({result.returncode}): " + (result.stderr + result.stdout).decode(errors="replace")[-1600:])
    return result.stdout

tool.parent.mkdir(parents=True, exist_ok=True)
sources = [root / "Scripts/reference-signer.cpp"]
sources += [p for p in sorted((root / "Vendor/ZSign").glob("*.cpp")) if p.name not in {"zsign.cpp", "certcheck.cpp"}]
sources += [p for p in sorted((root / "Vendor/ZSign/common").glob("*.cpp")) if p.name != "archive.cpp"]
run(["c++", "-O2", "-std=c++17", "-Wno-deprecated-declarations", "-I" + str(root / "Vendor/ZSign"), "-I" + str(root / "Vendor/ZSign/common"), "-I" + str(openssl / "include"), *sources, "-L" + str(openssl / "lib"), "-lssl", "-lcrypto", "-lz", "-o", tool])

with tempfile.TemporaryDirectory(prefix="retools-selfsigned-reference-") as temporary:
    work = Path(temporary)
    app = work / "Payload/Retools.app"
    shutil.copytree(source, app)
    for file in app.rglob("embedded.mobileprovision"): file.unlink()
    key, cert, der, p12 = [work / name for name in ["key.pem", "certificate.pem", "certificate.der", "build.p12"]]
    password = secrets.token_urlsafe(24)
    run([openssl / "bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650", "-subj", "/CN=Retools Reference Build/OU=SELFSIGNED/O=Retools", "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,digitalSignature,keyCertSign", "-addext", "extendedKeyUsage=codeSigning", "-keyout", key, "-out", cert])
    run([openssl / "bin/openssl", "x509", "-in", cert, "-outform", "DER", "-out", der])
    run([openssl / "bin/openssl", "pkcs12", "-export", "-in", cert, "-inkey", key, "-certfile", cert, "-out", p12, "-passout", "pass:" + password])
    now = datetime.datetime.now(datetime.UTC).replace(tzinfo=None)
    profile = {
        "AppIDName": "Retools reference — re-sign before installation",
        "Name": "Retools self-signed build placeholder",
        "UUID": str(uuid.uuid4()).upper(), "Version": 1, "Platform": ["iOS"],
        "TeamIdentifier": ["RETOOLSTMP"], "TeamName": "Retools reference metadata",
        "ApplicationIdentifierPrefix": ["RETOOLSTMP"],
        "CreationDate": now, "ExpirationDate": now + datetime.timedelta(days=3650),
        "DeveloperCertificates": [der.read_bytes()],
        "Entitlements": {"application-identifier": "RETOOLSTMP.dev.retools.ios", "get-task-allow": False},
        "ProvisionsAllDevices": False,
    }
    plain_profile, mobileprovision = work / "profile.plist", work / "embedded.mobileprovision"
    plain_profile.write_bytes(plistlib.dumps(profile))
    run([openssl / "bin/openssl", "cms", "-sign", "-binary", "-nodetach", "-in", plain_profile, "-signer", cert, "-inkey", key, "-outform", "DER", "-out", mobileprovision])
    run([tool, app, p12, password, mobileprovision, "dev.retools.ios"])
    run(["codesign", "--verify", "--deep", "--strict", app])
    info = plistlib.loads((app / "Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == "dev.retools.ios" and info.get("RetoolsPrivateSandbox") is True
    # ZSign embeds the placeholder profile in the main app and in each app extension.
    profiles = list(app.rglob("embedded.mobileprovision"))
    assert len(profiles) == 1 + len(list(app.rglob("*.appex")))
    assert not list(app.rglob("*.p12")) and not list(app.rglob("*.pem"))
    output = work / destination.name
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted((work / "Payload").rglob("*")): archive.write(path, path.relative_to(work))
    with zipfile.ZipFile(output) as archive: assert archive.testzip() is None
    verified = work / "verified"
    run(["ditto", "-x", "-k", output, verified])
    run(["codesign", "--verify", "--deep", "--strict", verified / "Payload/Retools.app"])
    destination.parent.mkdir(parents=True, exist_ok=True)
    output.replace(destination)

digest = hashlib.sha256(destination.read_bytes()).hexdigest()
Path(str(destination) + ".sha256").write_text(digest + "  " + destination.name + "\n")
report = {"bundle_id": "dev.retools.ios", "private_sandbox": True, "signature": "self-signed build reference", "certificate_subject": "Retools Reference Build / SELFSIGNED", "profile_count": len(profiles), "personal_signing_material": False, "private_key_files": 0, "final_archive_signatures_verified": True, "direct_ios_installation_authorized": False, "sha256": digest}
(root / "Artifacts/SandboxPackage.json").write_text(json.dumps(report, indent=2) + "\n")
print("Created", destination)
