#!/usr/bin/env python3
"""Assemble Android SDK from component zips into D:/Android/Sdk layout."""
import zipfile, os, shutil, sys, time

SDK = "D:/Android/Sdk"

def extract(zip_path, inner_root, dest_dir, source_props=None):
    """Extract zip with inner folder rename to dest_dir."""
    if os.path.exists(dest_dir):
        print(f"skip {dest_dir} (exists)")
        return
    os.makedirs(os.path.dirname(dest_dir), exist_ok=True)
    t = time.time()
    with zipfile.ZipFile(zip_path) as z:
        members = z.namelist()
        # strip the common leading folder
        prefix = inner_root + "/" if inner_root else ""
        os.makedirs(dest_dir, exist_ok=True)
        for m in members:
            if m.endswith("/"):
                continue
            rel = m[len(prefix):] if prefix and m.startswith(prefix) else m
            out = os.path.join(dest_dir, rel)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with z.open(m) as src, open(out, "wb") as dst:
                shutil.copyfileobj(src, dst)
    print(f"extracted {zip_path} -> {dest_dir} in {int(time.time()-t)}s")

def write_props(dest_dir, pkg, version):
    os.makedirs(dest_dir, exist_ok=True)
    with open(os.path.join(dest_dir, "source.properties"), "w", newline="\n") as f:
        f.write(f"Pkg.Desc=Android SDK\nPkg.Revision={version}\n")
        if pkg.startswith("platforms"):
            f.write("AndroidVersion.ApiLevel=35\nAndroidVersion.CodeName=\n")
    print(f"wrote source.properties for {pkg}")

TMP = os.environ.get("TEMP", "C:/Program Files/Git/tmp").replace("\\", "/")
JOBS = [
    # (zip, inner folder, dest, pkgid, revision)
    (f"{TMP}/sdk_platform35.zip", "android-35-ext15", f"{SDK}/platforms/android-35", "platforms;android-35", "3"),
    (f"{TMP}/sdk_platform36.zip", None, f"{SDK}/platforms/android-36", "platforms;android-36", "2"),
    (f"{TMP}/sdk_buildtools35.zip", "android-15", f"{SDK}/build-tools/35.0.0", "build-tools;35.0.0", "35.0.0"),
    (f"{TMP}/sdk_buildtools34.zip", "android-14", f"{SDK}/build-tools/34.0.0", "build-tools;34.0.0", "34.0.0"),
    (f"{TMP}/sdk_buildtools36.zip", "android-16", f"{SDK}/build-tools/36.0.0", "build-tools;36.0.0", "36.0.0"),
]

if __name__ == "__main__":
    only = sys.argv[1:] or None
    for zpath, inner, dest, pkg, rev in JOBS:
        if only and pkg not in only and zpath not in only:
            continue
        if not os.path.exists(zpath):
            print(f"MISSING {zpath}")
            continue
        # peek inner root from the zip
        with zipfile.ZipFile(zpath) as z:
            first = z.namelist()[0]
            root = first.split("/")[0] if "/" in first else None
        if inner is None:
            extract(zpath, root, dest)
        else:
            if root != inner:
                print(f"note: {zpath} root={root!r} expected={inner!r}")
            extract(zpath, root, dest)
        write_props(dest, pkg, rev)
    print("DONE")
