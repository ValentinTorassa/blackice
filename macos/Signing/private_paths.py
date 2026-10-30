"""Owner-controlled build/signing paths; no signing or privilege operations."""
import os
from pathlib import Path
import stat
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def checked_node(path, *, directory=False):
    info = path.lstat()
    require(not stat.S_ISLNK(info.st_mode), "symlink is not an owned build/signing path")
    require(info.st_uid == os.geteuid(), "build/signing path must belong to the current user")
    require(info.st_mode & 0o022 == 0, "build/signing path is group- or other-writable")
    if directory:
        require(stat.S_ISDIR(info.st_mode), "build/signing parent must be a directory")
    else:
        require(stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode), "unexpected build/signing file type")
        if stat.S_ISREG(info.st_mode):
            require(info.st_nlink == 1, "hard-linked build/signing file is not accepted")


def checked_ancestors(path):
    # Canonical paths are used after this check, so /tmp's root-owned macOS
    # alias cannot later redirect a build. Only OS sticky temp roots may be
    # shared/writable; private descendants must pass the ordinary checks.
    temporary_roots = {Path("/tmp").resolve(), Path("/private/tmp").resolve()}
    for parent in path.parents:
        info = parent.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid in {0, os.geteuid()}, "untrusted build/signing ancestor")
        sticky_root = parent in temporary_roots and info.st_uid == 0 and info.st_mode & stat.S_ISVTX
        require(info.st_mode & 0o022 == 0 or sticky_root, "writable build/signing ancestor")


def checked_directory(path):
    requested = Path(path).absolute()
    require(not requested.is_symlink(), "build/signing directory cannot be a symlink")
    canonical = requested.resolve(strict=True)
    checked_node(canonical, directory=True)
    checked_ancestors(canonical)
    return canonical


def prepare_directory(path):
    requested = Path(path).absolute()
    require(not requested.is_symlink(), "build directory cannot be a symlink")
    canonical = requested.resolve()
    missing = []
    cursor = canonical
    while not cursor.exists():
        missing.append(cursor)
        cursor = cursor.parent
    # Validate the existing prefix before creating anything below it.
    checked_ancestors(cursor / "prospective-child")
    for directory in reversed(missing):
        directory.mkdir(mode=0o700)
        checked_node(directory, directory=True)
    return checked_directory(canonical)


def checked_tree(path):
    requested = Path(path).absolute()
    require(not requested.is_symlink(), "build/signing tree cannot be a symlink")
    canonical = requested.resolve(strict=True)
    checked_directory(canonical.parent)
    checked_node(canonical, directory=True)
    for child in canonical.rglob("*"):
        checked_node(child)
    return canonical


if __name__ == "__main__":
    try:
        require(len(sys.argv) == 3 and sys.argv[1] in {"directory", "tree"},
                "usage: private_paths.py directory|tree PATH")
        result = prepare_directory(sys.argv[2]) if sys.argv[1] == "directory" else checked_tree(sys.argv[2])
        print(result)
    except (ValueError, OSError) as error:
        raise SystemExit("private-paths: " + str(error))
