#!/usr/bin/env python3
"""Fail closed on unexpected source/payload files; never print file contents."""
import argparse
import fnmatch
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import zipfile

APP_NAME = "Install OBS Live Beauty.app"
PLUGIN_NAME = "obs-live-beauty.plugin"
MACHO_MAGICS = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
ROOT_TEXT = {"CMakeLists.txt", "Info.plist.in", "LICENSE", "COPYING", "NOTICE", "NOTICE.md", "AGENTS.md", ".gitignore", ".gitattributes", ".editorconfig", "SECURITY.md", "CONTRIBUTING.md", "CHANGELOG.md", "ACKNOWLEDGMENTS.md", "THIRD-PARTY.md"}
PRIVATE_PATH = re.compile(rb"/(?:Users|Volumes|private/(?:var|tmp)|var/folders)/[^\x00\r\n\"'<>]{1,160}")
WINDOWS_PRIVATE_PATH = re.compile(rb"[A-Za-z]:[\\/]Users[\\/][^\x00\r\n\"'<>]{1,100}")
SECRET = re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[A-Z0-9]{16}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)")
BANNED_SUFFIX = {".dylib", ".so", ".dll", ".lua", ".model", ".bin", ".dat", ".onnx", ".tflite", ".pb", ".caffemodel", ".mlmodel", ".mlpackage", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".icns", ".ico", ".svg", ".ttf", ".otf", ".woff", ".zip", ".dmg", ".pkg", ".p12", ".pem", ".key", ".mobileprovision"}
MAX_FILE_BYTES = 64 * 1024 * 1024


def fail(message):
    raise ValueError(message)


def metadata(path):
    return any(part.startswith("._") or part in {".DS_Store", "__MACOSX"} for part in path.parts)


def safe_path(name):
    path = pathlib.PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or "\\" in name:
        fail(f"Unsafe payload path: {name}")
    if metadata(path):
        fail(f"Filesystem metadata is not a payload file: {name}")
    if path.suffix.lower() in BANNED_SUFFIX:
        fail(f"Forbidden redistributed file type: {name}")
    return path


def source_allowed(path):
    parts = path.parts
    if len(parts) == 1:
        return path.name in ROOT_TEXT or fnmatch.fnmatch(path.name, "README*.md") or path.name.startswith("LICENSE-")
    parent, rest = parts[0], parts[1:]
    if parent == "src" and len(rest) == 1:
        return path.suffix in {".h", ".mm", ".cpp", ".c"} and not path.name.lower().startswith("wink")
    if parent == "installer" and len(rest) == 1:
        return path.name in {"Info.plist.in", "Info.plist"} or path.suffix in {".mm", ".h", ".sh"}
    if parent == "tools" and len(rest) == 1:
        return path.suffix in {".sh", ".py"}
    if parent == "docs":
        return path.suffix == ".md"
    if str(path) in {"resources/install-manifest.json", "data/panel.html", "data/windows-catalog.json"}:
        return True
    if len(parts) == 3 and parts[:2] == ("data", "locale"):
        return path.suffix == ".ini"
    if len(parts) == 3 and parts[:2] == ("data", "detector"):
        return path.suffix == ".json"
    return len(parts) == 3 and parts[:2] == (".github", "workflows") and path.suffix in {".yml", ".yaml"}


def plugin_allowed(path):
    name = str(path)
    return name in {"Contents/Info.plist", "Contents/MacOS/obs-live-beauty", "Contents/_CodeSignature/CodeResources", "Contents/Resources/panel.html", "Contents/Resources/windows-catalog.json"} or (
        len(path.parts) == 4 and path.parts[:3] in {("Contents", "Resources", "locale"), ("Contents", "Resources", "detector")}
        and path.suffix == (".ini" if path.parts[2] == "locale" else ".json")
    )


def app_allowed(path):
    name = str(path)
    if name in {"Contents/Info.plist", "Contents/PkgInfo", "Contents/MacOS/obs-live-beauty-installer", "Contents/_CodeSignature/CodeResources", "Contents/Resources/install-manifest.json", "Contents/Resources/windows-catalog.json", "Contents/Resources/LICENSE", "Contents/Resources/README.md", "Contents/Resources/README.en.md", "Contents/Resources/AGENTS.md", "Contents/Resources/THIRD-PARTY.md", "Contents/Resources/ACKNOWLEDGMENTS.md", "Contents/Resources/NOTICE", "Contents/Resources/NOTICE.md"}:
        return True
    if len(path.parts) == 3 and path.parts[:2] == ("Contents", "Resources") and path.name.startswith("LICENSE-"):
        return True
    if len(path.parts) == 4 and path.parts[:3] == ("Contents", "Resources", "detector"):
        return path.suffix == ".json"
    prefix = pathlib.PurePosixPath("Contents/Resources") / PLUGIN_NAME
    if path.is_relative_to(prefix):
        return plugin_allowed(path.relative_to(prefix))
    return False


def binary_allowed(mode, name):
    if mode == "plugin":
        return name == "Contents/MacOS/obs-live-beauty"
    return name in {"Contents/MacOS/obs-live-beauty-installer", f"Contents/Resources/{PLUGIN_NAME}/Contents/MacOS/obs-live-beauty"}


def inspect_file(mode, name, data):
    path = safe_path(name)
    allowed = source_allowed(path) if mode == "source" else plugin_allowed(path) if mode == "plugin" else app_allowed(path)
    if not allowed:
        fail(f"File is outside the {mode} allowlist: {name}")
    # A documented release-volume mount is public packaging metadata, not a workstation path.
    public_volume = rb"/" + rb"Volumes/OBS Live Beauty(?: [0-9]+\.[0-9]+\.[0-9]+)?/"
    path_data = re.sub(public_volume, b"/mounted-release/", data)
    if PRIVATE_PATH.search(path_data) or WINDOWS_PRIVATE_PATH.search(path_data):
        fail(f"Private machine path found in: {name}")
    if SECRET.search(data):
        fail(f"Credential material found in: {name}")
    macho = data[:4] in MACHO_MAGICS
    expected_binary = mode != "source" and binary_allowed(mode, name)
    if expected_binary != macho:
        fail(f"Unexpected binary/text type: {name}")
    if not expected_binary:
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            fail(f"Non-text content in a source/resource file: {name}")
        if path.suffix == ".json":
            try:
                json.loads(text)
            except ValueError:
                fail(f"Invalid JSON metadata: {name}")


def tree_files(root, source=False):
    def walk_error(error):
        fail(f"Cannot scan a source/payload directory: {error.filename}")
    for folder, dirs, files in os.walk(root, followlinks=False, onerror=walk_error):
        folder = pathlib.Path(folder)
        relative_folder = folder.relative_to(root)
        if source:
            dirs[:] = [name for name in dirs if name != "__pycache__" and not metadata(pathlib.PurePosixPath(name))
                       and not (relative_folder == pathlib.Path('.') and name in {".git", "build", "dist"})]
        for name in dirs:
            if (folder/name).is_symlink():
                fail(f"Symlinks are not allowed in source/payload: {(folder/name).relative_to(root)}")
        for name in sorted(files):
            path = folder/name
            rel = path.relative_to(root)
            if source and rel.as_posix() == ".git":
                continue
            if source and metadata(rel):
                continue
            if path.is_symlink():
                fail(f"Symlinks are not allowed in source/payload: {rel}")
            if path.is_file():
                if source and not source_allowed(safe_path(rel.as_posix())):
                    fail(f"File is outside the source allowlist: {rel}")
                if path.stat().st_size > MAX_FILE_BYTES:
                    fail(f"Source/payload file is unexpectedly large: {rel}")
                yield rel.as_posix(), path.read_bytes()


def verify_required(mode, names):
    if mode == "source":
        return
    required = {"Contents/Info.plist", "Contents/MacOS/obs-live-beauty"} if mode == "plugin" else {
        "Contents/Info.plist", "Contents/MacOS/obs-live-beauty-installer", "Contents/Resources/install-manifest.json",
        "Contents/Resources/windows-catalog.json", "Contents/Resources/LICENSE", "Contents/Resources/README.md",
        "Contents/Resources/THIRD-PARTY.md", "Contents/Resources/ACKNOWLEDGMENTS.md",
        f"Contents/Resources/{PLUGIN_NAME}/Contents/Info.plist", f"Contents/Resources/{PLUGIN_NAME}/Contents/MacOS/obs-live-beauty",
    }
    missing = required.difference(names)
    if missing:
        fail("Missing required payload files: " + ", ".join(sorted(missing)))
    if mode == "app" and not any(n.startswith("Contents/Resources/detector/") and n.endswith(".json") for n in names):
        fail("Missing detector JSON metadata")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("source", "plugin", "app", "zip"))
    parser.add_argument("path", type=pathlib.Path)
    parser.add_argument("--compare-app", type=pathlib.Path)
    args = parser.parse_args()
    mode = "app" if args.mode == "zip" else args.mode
    names = set()
    if args.mode == "zip":
        with zipfile.ZipFile(args.path) as archive:
            for member in archive.infolist():
                safe_path(member.filename.rstrip('/'))
                path = pathlib.PurePosixPath(member.filename)
                if path.parts[:1] != (APP_NAME,):
                    fail(f"Unexpected ZIP root: {member.filename}")
                if member.is_dir():
                    continue
                if stat.S_ISLNK(member.external_attr >> 16):
                    fail(f"ZIP symlink: {member.filename}")
                if member.file_size > MAX_FILE_BYTES:
                    fail(f"ZIP member is unexpectedly large: {member.filename}")
                name = path.relative_to(APP_NAME).as_posix()
                if name in names:
                    fail(f"Duplicate ZIP entry: {name}")
                data = archive.read(member)
                inspect_file(mode, name, data)
                names.add(name)
                if args.compare_app and (args.compare_app/name).read_bytes() != data:
                    fail(f"ZIP differs from staged app: {name}")
        if args.compare_app:
            staged_names = {n for n, _ in tree_files(args.compare_app)}
            if names != staged_names:
                fail("ZIP file list differs from staged app")
    else:
        if not args.path.is_dir():
            fail(f"Directory not found: {args.path}")
        for name, data in tree_files(args.path, mode == "source"):
            inspect_file(mode, name, data)
            names.add(name)
        if mode == "source" and (args.path/".git").exists():
            env = dict(os.environ)
            clt = pathlib.Path('/Library/Developer/CommandLineTools')
            if clt.is_dir():
                env.setdefault('DEVELOPER_DIR', str(clt))
            result = subprocess.run(["git", "-C", str(args.path), "ls-files", "-z"], capture_output=True, check=True, env=env)
            for name in result.stdout.decode().split("\0"):
                if not name:
                    continue
                path = safe_path(name)
                if not source_allowed(path):
                    fail(f"Tracked file is outside the source allowlist: {name}")
    verify_required(mode, names)
    print(f"PASS: {args.mode} allowlist and sensitive-content scan ({len(names)} files)")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, RuntimeError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
