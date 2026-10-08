#!/usr/bin/env python3
"""Parallel chunked downloader (range requests) for big files on the mirror."""
import os, sys, threading, time, urllib.request

URL = sys.argv[1]
OUT = sys.argv[2]
NCHUNK = int(sys.argv[3]) if len(sys.argv) > 3 else 8

def total_size():
    req = urllib.request.Request(URL, method="HEAD")
    with urllib.request.urlopen(req, timeout=30) as r:
        return int(r.headers["Content-Length"])

def fetch(url, out_path, start, end, idx, retries=5):
    for attempt in range(retries):
        try:
            headers = {"Range": f"bytes={start}-{end}"}
            req = urllib.request.Request(url, headers=headers)
            mode = "wb"
            if os.path.exists(out_path) and os.path.getsize(out_path) == (end - start + 1):
                print(f"[{idx}] already done", flush=True)
                return
            if os.path.exists(out_path):
                mode = "ab"
                start = start + os.path.getsize(out_path)
                headers["Range"] = f"bytes={start}-{end}"
                req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=60) as r, open(out_path, mode) as f:
                while True:
                    b = r.read(1 << 20)
                    if not b:
                        break
                    f.write(b)
            size = os.path.getsize(out_path)
            if size >= (end - start + 1) or size == 0:
                return
        except Exception as e:
            print(f"[{idx}] retry {attempt}: {str(e)[:60]}", flush=True)
            time.sleep(2)
    raise RuntimeError(f"chunk {idx} failed")

def main():
    t0 = time.time()
    size = total_size()
    print(f"total {size} ({size//1048576} MiB), {NCHUNK} chunks", flush=True)
    per = size // NCHUNK
    parts = [(i * per, (size - 1) if i == NCHUNK - 1 else ((i + 1) * per - 1)) for i in range(NCHUNK)]
    paths = [f"{OUT}.part{i}" for i in range(NCHUNK)]
    ths = []
    for i, (s, e) in enumerate(parts):
        th = threading.Thread(target=fetch, args=(URL, paths[i], s, e, i))
        th.start(); ths.append(th)
        time.sleep(0.2)
    for th in ths:
        th.join()
    with open(OUT, "wb") as out:
        for p in paths:
            with open(p, "rb") as f:
                shutil_out = out.write(f.read())
            os.remove(p)
    got = os.path.getsize(OUT)
    print(f"done {got} bytes in {int(time.time()-t0)}s (avg {got//max(1,int(time.time()-t0))//1024} KB/s)", flush=True)

if __name__ == "__main__":
    main()
