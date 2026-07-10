#!/usr/bin/env python3
import argparse
import gzip
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path
from typing import Optional


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Rewrap an upstream macOS app bundle in a Bearly-branded archive.")
    parser.add_argument("--archive", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--source-app-name", required=True)
    parser.add_argument("--app-name", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--display-name", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--archive-root", required=True)
    parser.add_argument("--license-file", required=True)
    parser.add_argument("--icon-file", default="")
    parser.add_argument("--root-binary-name", default="")
    return parser.parse_args()


def find_directory(root: Path, name: str) -> Path:
    matches = [path for path in root.rglob(name) if path.is_dir()]
    if len(matches) != 1:
        raise RuntimeError(f"expected exactly one {name}, found {len(matches)}")
    return matches[0]


def is_inside_app_bundle(path: Path) -> bool:
    return any(part.endswith(".app") for part in path.parts)


def find_root_file(root: Path, name: str) -> Optional[Path]:
    matches = [path for path in root.rglob(name) if path.is_file() and not is_inside_app_bundle(path)]
    if len(matches) == 0:
        return None
    if len(matches) != 1:
        raise RuntimeError(f"expected at most one {name}, found {len(matches)}")
    return matches[0]


def update_plist(app_path: Path, bundle_id: str, display_name: str, version: str, has_custom_icon: bool) -> None:
    plist_path = app_path / "Contents" / "Info.plist"
    if not plist_path.is_file():
        raise RuntimeError(f"missing Info.plist: {plist_path}")
    with plist_path.open("rb") as handle:
        plist = plistlib.load(handle)
    plist["CFBundleIdentifier"] = bundle_id
    plist["CFBundleName"] = display_name
    plist["CFBundleDisplayName"] = display_name
    plist["CFBundleShortVersionString"] = version
    plist["CFBundleVersion"] = version
    plist["NSHumanReadableCopyright"] = "Copyright (c) Bearly. Contains CUA driver components licensed under MIT."
    if has_custom_icon:
        plist["CFBundleIconFile"] = "AppIcon"
        plist["CFBundleIconName"] = "AppIcon"
    with plist_path.open("wb") as handle:
        plistlib.dump(plist, handle, sort_keys=False)


def remove_stale_signature(app_path: Path) -> None:
    signature_dir = app_path / "Contents" / "_CodeSignature"
    if signature_dir.exists():
        shutil.rmtree(signature_dir)
    code_resources = app_path / "Contents" / "CodeResources"
    if code_resources.exists() or code_resources.is_symlink():
        code_resources.unlink()


def copy_license(license_file: Path, archive_root: Path, app_path: Path) -> None:
    if not license_file.is_file():
        raise RuntimeError(f"missing license file: {license_file}")
    archive_license = archive_root / "LICENSE.cua-driver.md"
    shutil.copy2(license_file, archive_license)
    resources_dir = app_path / "Contents" / "Resources"
    resources_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(license_file, resources_dir / "CUA_LICENSE.md")


def copy_icon(icon_file: Path, app_path: Path) -> None:
    if not icon_file.is_file():
        raise RuntimeError(f"invalid ICNS icon file: {icon_file}")
    with icon_file.open("rb") as handle:
        if handle.read(4) != b"icns":
            raise RuntimeError(f"invalid ICNS icon file: {icon_file}")
    resources_dir = app_path / "Contents" / "Resources"
    resources_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(icon_file, resources_dir / "AppIcon.icns")


def create_archive(source_root: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as raw_output:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw_output, mtime=0) as gzip_output:
            with tarfile.open(fileobj=gzip_output, mode="w") as archive:
                for path in sorted(source_root.rglob("*")):
                    arcname = path.relative_to(source_root.parent)
                    tar_info = archive.gettarinfo(str(path), arcname=str(arcname))
                    tar_info.uid = 0
                    tar_info.gid = 0
                    tar_info.uname = ""
                    tar_info.gname = ""
                    tar_info.mtime = 0
                    if tar_info.isfile():
                        with path.open("rb") as handle:
                            archive.addfile(tar_info, handle)
                    else:
                        archive.addfile(tar_info)


def safe_extract_tar(archive: tarfile.TarFile, destination: Path) -> None:
    destination = destination.resolve()
    for member in archive.getmembers():
        target = (destination / member.name).resolve()
        if target != destination and destination not in target.parents:
            raise RuntimeError(f"archive member escapes extraction directory: {member.name}")
        if member.issym() or member.islnk():
            link_name = Path(member.linkname)
            link_base = target.parent if member.issym() else destination
            link_target = link_name if link_name.is_absolute() else link_base / link_name
            resolved_link_target = link_target.resolve()
            if resolved_link_target != destination and destination not in resolved_link_target.parents:
                raise RuntimeError(f"archive link escapes extraction directory: {member.name} -> {member.linkname}")
    archive.extractall(destination)


def main() -> int:
    args = parse_args()
    archive_path = Path(args.archive).resolve()
    output_path = Path(args.output).resolve()
    license_file = Path(args.license_file).resolve()
    icon_file = Path(args.icon_file).resolve() if args.icon_file else None

    with tempfile.TemporaryDirectory(prefix="crossbins-rewrap-macos-app-") as temp:
        temp_path = Path(temp)
        extract_root = temp_path / "extract"
        staging_root = temp_path / args.archive_root
        extract_root.mkdir()
        staging_root.mkdir()

        with tarfile.open(archive_path, "r:gz") as archive:
            safe_extract_tar(archive, extract_root)

        source_app = find_directory(extract_root, args.source_app_name)
        target_app = staging_root / args.app_name
        shutil.copytree(source_app, target_app, symlinks=True)
        if icon_file:
            copy_icon(icon_file, target_app)
        update_plist(target_app, args.bundle_id, args.display_name, args.version, icon_file is not None)
        remove_stale_signature(target_app)
        copy_license(license_file, staging_root, target_app)

        if args.root_binary_name:
            root_binary = find_root_file(extract_root, args.root_binary_name)
            if not root_binary:
                raise RuntimeError(f"missing root binary: {args.root_binary_name}")
            target_binary = staging_root / args.root_binary_name
            shutil.copy2(root_binary, target_binary)
            target_binary.chmod(target_binary.stat().st_mode | 0o755)

        create_archive(staging_root, output_path)

    subprocess.run(["tar", "tzf", str(output_path)], check=True, stdout=subprocess.DEVNULL)
    return 0


if __name__ == "__main__":
    sys.exit(main())
