#!/usr/bin/env python3
"""Package existing Mac products without registering another input source."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "出海王输入法.app"
IME_NAME = "出海王输入法键盘.app"


def run(*args, capture=False):
    return subprocess.run(
        [str(a) for a in args], check=True, text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def plist(path):
    return plistlib.loads(path.read_bytes())


def verify(path):
    run("codesign", "--verify", "--deep", "--strict", "--verbose=2", path)


def signature(path):
    result = run("codesign", "-d", "--verbose=4", path, capture=True)
    return result.stdout + result.stderr


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path.home() / "Library/Developer/Haiwang/Preview" / APP_NAME)
    parser.add_argument("--output", type=Path, default=Path.home() / "Library/Developer/Haiwang/ReleasePackages")
    parser.add_argument("--identity", help="Developer ID Application identity name or SHA-1")
    parser.add_argument("--keychain", type=Path, help="Optional signing keychain")
    parser.add_argument("--notary-profile", help="Existing notarytool keychain profile; enables full notarization")
    parser.add_argument("--notary-keychain", type=Path, help="Keychain containing that notarytool profile")
    parser.add_argument("--development", action="store_true", help="Make an explicitly marked ad-hoc development DMG")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Packaging requires macOS.")
    if args.development and (args.identity or args.notary_profile):
        parser.error("Development packaging cannot use a release identity or notarization profile.")
    if args.notary_keychain and not args.notary_profile:
        parser.error("--notary-keychain requires --notary-profile.")

    source = args.app.expanduser().resolve()
    output = args.output.expanduser().resolve()
    if output in (Path("/"), Path.home(), ROOT) or any(
        name in output.parts for name in ("Mobile Documents", "CloudStorage")
    ):
        parser.error("Use a dedicated local output directory outside cloud storage.")
    info = plist(source / "Contents/Info.plist")
    if info.get("CFBundleIdentifier") != "com.haiwang.app":
        parser.error("Source is not the SailKing Mac app.")
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", version) or not re.fullmatch(r"[0-9]+", build):
        parser.error("Unexpected app version or build number.")
    payload = source / "Contents/Library/InputMethodInstaller"
    ime_info = plist(payload / IME_NAME / "Contents/Info.plist")
    if (ime_info.get("CFBundleIdentifier") != "com.haiwang.inputmethod.Haiwang"
            or ime_info.get("CFBundleShortVersionString") != version
            or ime_info.get("CFBundleVersion") != build):
        parser.error("Embedded input method is missing or has a different version.")
    for name in ("haiwang-input-sources", "install-input-method.sh"):
        if not (payload / name).is_file():
            parser.error("Embedded installation payload is incomplete.")
    for candidate in (source, payload / IME_NAME, payload / "haiwang-input-sources"):
        verify(candidate)
    binary = source / "Contents/MacOS" / info["CFBundleExecutable"]
    architectures = run("lipo", "-archs", binary, capture=True).stdout.strip().split()
    if architectures != ["arm64"]:
        parser.error("This release lane expects an arm64 app.")

    team = None
    identity = "-"
    if not args.development:
        cmd = ["security", "find-identity", "-v", "-p", "codesigning"]
        if args.keychain:
            cmd.append(str(args.keychain.expanduser()))
        identities = re.findall(
            r'([0-9A-F]{40}) "(Developer ID Application: [^"\n]+)"',
            run(*cmd, capture=True).stdout,
        )
        matches = [item for item in identities if args.identity in (None, item[0], item[1])]
        if len(matches) != 1:
            parser.error("Select one valid Developer ID Application identity with a private key. Use --development only for a non-public candidate.")
        identity = matches[0][0]
        match = re.search(r"\(([A-Z0-9]{10})\)$", matches[0][1])
        if not match:
            parser.error("Could not determine the signing team.")
        team = match[1]

    output.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    working = Path(tempfile.mkdtemp(prefix=f"{version}-{stamp}.", dir=output))
    stage = working / "DMG"
    stage.mkdir()
    app = stage / APP_NAME
    run("ditto", "--noextattr", "--norsrc", "--noqtn", source, app)
    embedded = app / "Contents/Library/InputMethodInstaller"
    ime = embedded / IME_NAME
    notices = app / "Contents/Resources/DistributionNotices"
    notices.mkdir()
    for name in ("LICENSE", "PRIVACY.md", "THIRD_PARTY_NOTICES.md"):
        run("ditto", ROOT / name, notices / name)

    def sign(path):
        cmd = ["codesign", "--force", "--sign", identity, "--options", "runtime"]
        if not args.development:
            cmd.append("--timestamp")
        if args.keychain:
            cmd.extend(["--keychain", str(args.keychain.expanduser())])
        run(*cmd, path)
        verify(path)
        if team:
            details = signature(path)
            if f"TeamIdentifier={team}" not in details or "Authority=Developer ID Application:" not in details:
                raise RuntimeError(f"Unexpected signing authority: {path.name}")
            if "runtime" not in details or "Timestamp=" not in details:
                raise RuntimeError(f"Hardened Runtime or secure timestamp missing: {path.name}")

    submissions = []

    def notarize(path, label):
        cmd = ["xcrun", "notarytool", "submit", str(path), "--keychain-profile", args.notary_profile, "--wait", "--output-format", "json"]
        if args.notary_keychain:
            cmd.extend(["--keychain", str(args.notary_keychain.expanduser())])
        result = subprocess.run(cmd, text=True, capture_output=True)
        (working / f"{label}-notary-result.json").write_text(result.stdout)
        (working / f"{label}-notary.log").write_text(result.stderr)
        result.check_returncode()
        submission = json.loads(result.stdout)
        submissions.append({"artifact": label, "id": submission.get("id"), "status": submission.get("status")})
        write_json(working / "notarization-submissions.json", submissions)
        if submission.get("status") != "Accepted":
            raise RuntimeError(f"Apple did not accept {label}; inspect the saved notarization result.")
        # Query independently, rather than infer acceptance from upload completion.
        query = ["xcrun", "notarytool", "info", submission["id"], "--keychain-profile", args.notary_profile, "--output-format", "json"]
        if args.notary_keychain:
            query.extend(["--keychain", str(args.notary_keychain.expanduser())])
        confirmed = json.loads(run(*query, capture=True).stdout)
        write_json(working / f"{label}-notary-confirmed.json", confirmed)
        if confirmed.get("status") != "Accepted":
            raise RuntimeError(f"Acceptance was not confirmed for {label}.")

    # Library/InputMethodInstaller is a sealed resource directory, not a standard
    # nested-code directory. Sign and staple the IME before sealing its host app.
    for library in sorted((ime / "Contents/Frameworks").glob("*.dylib")):
        sign(library)
    sign(embedded / "haiwang-input-sources")
    sign(ime)
    if args.notary_profile:
        ime_zip = working / "input-method-notary.zip"
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", ime, ime_zip)
        notarize(ime_zip, "input-method")
        run("xcrun", "stapler", "staple", ime)
        run("xcrun", "stapler", "validate", ime)
        verify(ime)
    sign(app)
    if args.notary_profile:
        app_zip = working / "app-notary.zip"
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, app_zip)
        notarize(app_zip, "app")
        run("xcrun", "stapler", "staple", app)
        run("xcrun", "stapler", "validate", app)
        verify(app)
        verify(ime)
        run("spctl", "--assess", "--type", "execute", "--verbose=4", app)
        run("spctl", "--assess", "--type", "execute", "--verbose=4", ime)

    os.symlink("/Applications", stage / "Applications")
    development_note = "开发预览包：使用本机测试签名，未经 Apple 公证，不作为正式公开安装包。\n\n" if args.development else ""
    (stage / "安装说明.txt").write_text(development_note + "出海王输入法 / SailKing\nmacOS 26+ · Apple Silicon\n\n1. 把出海王输入法.app 拖到 Applications。\n2. 退出安装镜像，从应用程序打开 App。\n3. 按新手设置安装组件，并在系统键盘中添加出海王。\n4. 选择出海王，输入 nihao，按空格选择“你好”。\n\n普通拼音与英文无需翻译模型，翻译可按需准备。\n项目与详细说明：https://github.com/sapplex-sz/SailKing\n")
    for name in ("LICENSE", "PRIVACY.md", "THIRD_PARTY_NOTICES.md"):
        run("ditto", ROOT / name, stage / name)
    suffix = ".DEVELOPMENT" if args.development else ".UNNOTARIZED"
    stem = f"SailKing-{version}-macOS-arm64"
    dmg = working / f"{stem}{suffix}.dmg"
    run("hdiutil", "create", "-volname", f"SailKing {version}", "-srcfolder", stage, "-format", "UDZO", "-ov", dmg)
    run("hdiutil", "verify", dmg)
    if not args.development:
        run("codesign", "--force", "--sign", identity, "--timestamp", dmg)
        verify(dmg)
    if args.notary_profile:
        notarize(dmg, "dmg")
        run("xcrun", "stapler", "staple", dmg)
        run("xcrun", "stapler", "validate", dmg)
        run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=4", dmg)
        verify(app)
        verify(ime)
        published_name = working / f"{stem}.dmg"
        dmg.rename(published_name)
        dmg = published_name
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    (working / "SHA256SUMS.txt").write_text(f"{digest}  {dmg.name}\n")
    write_json(working / "package-manifest.json", {
        "version": version, "build": build, "architecture": "arm64",
        "team": team, "developerIdSigned": not args.development,
        "notarized": bool(args.notary_profile), "notarization": submissions,
        "artifact": dmg.name, "sha256": digest, "bytes": dmg.stat().st_size,
    })
    print(f"Package: {dmg}")
    if not args.notary_profile:
        print("This is a candidate only. Do not publish it as a notarized release.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Packaging stopped: {error}", file=sys.stderr)
        sys.exit(1)
