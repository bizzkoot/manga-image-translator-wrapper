#!/usr/bin/env python3
"""
Simple Webtoon image grabber for Naver (mobile/desktop URLs).
Saves page images into ./samples_in in reading order.

Usage:
  CLI (non-interactive):
    python scripts/grab_webtoon.py --url "https://m.comic.naver.com/webtoon/detail?..." [--out samples_in]

  CLI (interactive prompts):
    python scripts/grab_webtoon.py

  GUI (very simple):
    python scripts/grab_webtoon.py --gui

No external deps required (uses stdlib). Works best with Naver mobile pages.
"""

from __future__ import annotations

import os
import re
import sys
import ssl
import time
import json
from pathlib import Path
from urllib.parse import urlparse, urljoin, urlunparse
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError
from html import unescape


UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/127.0.0.0 Safari/537.36"
)


def fetch(url: str, referer: str | None = None, binary: bool = False, *, timeout: float = 20.0, attempts: int = 3, return_info: bool = False):
    """Fetch bytes with retries. Returns bytes or (bytes, headers) if return_info.
    Raises last error on repeated failure.
    """
    ctx = ssl.create_default_context()
    headers = {
        "User-Agent": UA,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
    }
    if referer:
        headers["Referer"] = referer
    delay = 0.5
    last_exc = None
    for i in range(1, attempts + 1):
        try:
            req = Request(url, headers=headers)
            with urlopen(req, context=ctx, timeout=timeout) as resp:
                data = resp.read()
                return (data, dict(resp.headers)) if return_info else data
        except (HTTPError, URLError, TimeoutError, ssl.SSLError) as e:
            last_exc = e
            if i >= attempts:
                break
            time.sleep(delay)
            delay *= 2
    if last_exc:
        raise last_exc
    raise RuntimeError("fetch failed without exception")


def normalize_naver_url(u: str) -> tuple[str, bool]:
    """If a Naver desktop webtoon detail URL is provided, rewrite to mobile.
    Returns (new_url, changed_flag).
    """
    try:
        p = urlparse(u)
        host = (p.netloc or '').lower()
        if host.endswith('comic.naver.com') and not host.startswith('m.'):
            if '/webtoon/detail' in p.path:
                new_netloc = 'm.comic.naver.com'
                new_url = urlunparse((p.scheme or 'https', new_netloc, p.path, p.params, p.query, p.fragment))
                return new_url, True
        return u, False
    except Exception:
        return u, False


def extract_image_urls(html: str, base: str) -> list[str]:
    # Find img tags and capture src-like attributes in order of appearance.
    # Supports src, data-src, data-original, data-image.
    img_attr_pattern = re.compile(
        r"<img[^>]+(?:data-src|data-original|data-image|src)\s*=\s*['\"]([^'\"]+)['\"][^>]*>",
        re.IGNORECASE,
    )
    urls = []
    seen = set()
    for m in img_attr_pattern.finditer(html):
        u = m.group(1)
        if u.startswith("data:"):
            continue
        # Resolve relative URLs
        u = urljoin(base, u)
        # Heuristic: prioritize Naver comic image hosts
        host = urlparse(u).netloc
        if not host:
            continue
        # Typical hosts: image-comic.pstatic.net, image-comic.pstatic.net
        if "pstatic.net" not in host and "comic.naver.net" not in host and "naver.net" not in host:
            # keep other images only if they look like large content (avoid icons)
            if not re.search(r"/webtoon/|/episode/|/content/|/image/", u):
                continue
        if u not in seen:
            seen.add(u)
            urls.append(u)
    # Additional filter: sort by likely page index if present
    def sort_key(u: str):
        m = re.search(r"/(\d{2,})/|_p(\d+)|page=(\d+)", u)
        if m:
            for g in m.groups():
                if g:
                    try:
                        return int(g)
                    except ValueError:
                        pass
        return 1_000_000

    # Collect additional candidates from inline JSON/script blocks (fallback)
    # Simple regex for absolute image URLs
    for m in re.finditer(r"https?://[^'\"\s>]+\.(?:jpg|jpeg|png|webp)(?:\?[^'\"\s>]*)?", html, re.I):
        u = m.group(0)
        host = urlparse(u).netloc
        if any(h in host for h in ("pstatic.net", "comic.naver.net", "naver.net")):
            if u not in seen:
                seen.add(u)
                urls.append(u)

    # Preserve original order but stabilize ties with guessed page number
    return sorted(list(dict.fromkeys(urls)), key=lambda x: (sort_key(x), urls.index(x)))


def infer_ext(url: str, fallback: str = ".jpg") -> str:
    path = urlparse(url).path.lower()
    for ext in (".jpg", ".jpeg", ".png", ".webp"):
        if path.endswith(ext):
            return ext
    return fallback


def is_image_bytes(data: bytes, ctype: str | None) -> bool:
    if ctype and ctype.lower().startswith("image/"):
        return True
    sig = data[:16]
    return (
        sig.startswith(b"\xff\xd8\xff") or               # JPEG
        sig.startswith(b"\x89PNG\r\n\x1a\n") or          # PNG
        sig.startswith(b"RIFF") and b"WEBP" in data[:64]    # WEBP
    ) and not sig.lstrip().startswith((b"<", b"{", b"<!"))


def download_images(urls: list[str], dest_dir: Path, referer: str, *, overwrite: bool = False, meta_dir: Path | None = None) -> tuple[list[Path], list[dict]]:
    dest_dir.mkdir(parents=True, exist_ok=True)
    if meta_dir is None:
        meta_dir = dest_dir
    meta_dir.mkdir(parents=True, exist_ok=True)
    saved_paths = []
    metas = []
    total = len(urls)
    pad = max(3, len(str(total)))
    (meta_dir / ".urls.txt").write_text("\n".join(urls) + "\n", encoding="utf-8")
    for idx, u in enumerate(urls, 1):
        ext = infer_ext(u)
        name = f"{idx:0{pad}d}{ext}"
        out = dest_dir / name
        if out.exists() and not overwrite:
            size = out.stat().st_size
            print(f"[skip] {idx}/{total}: {name} (exists, {size} bytes)")
            saved_paths.append(out)
            metas.append({"index": idx, "filename": name, "url": u, "size": size})
            continue
        try:
            data, info = fetch(u, referer=referer, binary=True, return_info=True)
        except Exception as e:
            print(f"[warn] failed {idx}/{total}: {u} -> {e}")
            continue
        ctype = info.get("Content-Type") if isinstance(info, dict) else None
        if not is_image_bytes(data, ctype):
            print(f"[warn] not an image {idx}/{total}: {u} (ctype={ctype})")
            continue
        out.write_bytes(data)
        size = len(data)
        print(f"[ok] {idx}/{total}: {name}")
        saved_paths.append(out)
        metas.append({"index": idx, "filename": name, "url": u, "size": size})
        # be polite
        time.sleep(0.05)
    return saved_paths, metas


def slugify(s: str) -> str:
    s = re.sub(r"[\s_]+", "-", s.strip())
    s = re.sub(r"[^A-Za-z0-9\-]+", "", s)
    s = re.sub(r"-+", "-", s)
    return s.strip("-")[:80]


def parse_chapter_label(url: str, html: str | None = None) -> tuple[str, dict]:
    """Return a stable chapter label and metadata for Naver Webtoon URLs.
    Label format: naver_<titleId>_<no>[_slug]
    """
    from urllib.parse import urlparse, parse_qs
    parsed = urlparse(url)
    qs = parse_qs(parsed.query)
    # get first value or empty string
    def qget(name: str) -> str:
        v = qs.get(name)
        return v[0] if v else ''

    title_id = qget('titleId')
    no = qget('no')
    site = 'naver'
    ep_title = None
    ep_main = None
    ep_sub = None
    ep_no_text = None
    if html:
        # Try to extract title/subtitle from known toolbar IDs
        def extract_by_id(doc: str, el_id: str) -> str | None:
            m = re.search(rf'<[^>]*id=["\']{re.escape(el_id)}["\'][^>]*>(.*?)</[^>]+>', doc, re.I | re.S)
            if not m:
                return None
            inner = m.group(1)
            # Drop tags and unescape entities
            inner = re.sub(r"<[^>]+>", " ", inner)
            inner = unescape(inner)
            return re.sub(r"\s+", " ", inner).strip()

        ep_main = extract_by_id(html, "titleName_toolbar")
        ep_sub = extract_by_id(html, "subTitle_toolbar")
        if ep_sub:
            mnum = re.search(r"(\d{1,5})", ep_sub)
            if mnum:
                ep_no_text = mnum.group(1)

        # Fallbacks: og:title or <title>
        m = re.search(r'<meta[^>]+property=["\']og:title["\'][^>]+content=["\']([^"\']+)["\']', html, re.I)
        if m:
            ep_title = m.group(1)
        else:
            m2 = re.search(r"<title>([^<]+)</title>", html, re.I)
            if m2:
                ep_title = m2.group(1)
    # Build a clean slug from main title (avoid subtitle noise like trailing -2)
    slug_base = ep_main or ep_title
    slug = slugify(slug_base) if slug_base else None
    if slug and re.search(r"-\d+$", slug):  # drop trailing dash+digits
        slug = re.sub(r"-\d+$", "", slug)
    # Prefer the number extracted from subtitle (page's own display); fallback to query param
    chapter_no = (ep_no_text or '') or no
    label = f"{site}_{title_id}_{chapter_no}" if (title_id or chapter_no) else (slug or "episode")
    if slug:
        label = f"{label}_{slug}"
    meta = {
        "site": site,
        "titleId": title_id,
        "no": no,
        "episode_title": ep_title,
        "episode_title_main": ep_main,
        "episode_subtitle": ep_sub,
        "episode_no_extracted": ep_no_text,
        "url": url,
    }
    return label, meta


def run_cli(url: str | None = None, out_dir: str | None = None, auto_process_hint: bool = True):
    if not url:
        url = input("Paste Webtoon URL: ").strip()
    if not url:
        print("No URL provided.")
        sys.exit(1)
    out_dir = out_dir or "samples_in"

    # Normalize Naver desktop URL to mobile for reliable image extraction
    url, changed = normalize_naver_url(url)
    if changed:
        print(f"[info] Rewriting to mobile page for better image access: {url}")
    print(f"[1/3] Fetching page: {url}")
    raw = fetch(url, referer=url, binary=True)
    html = raw.decode("utf-8", errors="ignore")

    # Decide concrete destination: if out_dir points to samples_in directly,
    # create a subfolder using chapter label to avoid mixing chapters.
    label, meta = parse_chapter_label(url, html)
    base_dest = Path(out_dir)
    dest = base_dest if base_dest.name != "samples_in" else (base_dest / label)

    print("[2/3] Parsing image URLs")
    urls = extract_image_urls(html, base=url)
    print(f"  Found {len(urls)} candidate images")
    if not urls:
        print("No images found. If this is a desktop URL, try the mobile page (m.comic.naver.com).")
        sys.exit(2)

    print(f"[3/3] Downloading to {dest}")
    overwrite = os.environ.get("GRAB_OVERWRITE", "0") == "1"
    meta_dir = Path("aggregated") / label
    saved, metas = download_images(urls, dest, referer=url, overwrite=overwrite, meta_dir=meta_dir)
    # Save manifest for later automation
    manifest = {"label": label, **meta, "count": len(saved), "images": metas}
    meta_dir.mkdir(parents=True, exist_ok=True)
    (meta_dir / ".chapter.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    # Also write a simple list for quick inspection
    with (meta_dir / "images.txt").open("w", encoding="utf-8") as f:
        for m in metas:
            f.write(f"{m['index']}\t{m['filename']}\t{m['url']}\t{m['size']}\n")
    print(f"Done. Saved {len(saved)} images to {dest}/")
    if auto_process_hint:
        # Show next-step hints for both single and two-pass
        print("Next options:")
        print(f"  [1] Two-pass:   bash scripts/mit_two_pass.sh --chapter {label} --input {dest}")
        print(f"  [2] Single-pass: CLI_INPUT_DIR={dest} bash scripts/mit_run.sh --use-gpu-limited --overwrite -v")
        # Interactive prompt to immediately process
        if sys.stdin.isatty():
            try:
                choice = input("Do now? [1=two-pass, 2=single-pass, 3=skip] (default 3): ").strip()
            except EOFError:
                choice = ""
            if choice == "1":
                import subprocess
                cmd = ["bash", "scripts/mit_two_pass.sh", "--chapter", label, "--input", str(dest)]
                print("Running:", " ".join(cmd))
                subprocess.run(cmd, check=False)
            elif choice == "2":
                import subprocess
                env = os.environ.copy()
                env["CLI_INPUT_DIR"] = str(dest)
                # Ensure overwrite to avoid stale outputs
                env["EXTRA_FLAGS"] = (env.get("EXTRA_FLAGS", "").strip() + " --overwrite").strip()
                cmd = ["bash", "scripts/mit_run.sh", "--use-gpu-limited", "-v"]
                print("Running:", " ".join([f"CLI_INPUT_DIR={dest}"] + cmd))
                subprocess.run(cmd, check=False, env=env)
            else:
                # Option 3: do nothing; best effort open the folder for convenience
                try:
                    import subprocess
                    if sys.platform == "darwin":
                        subprocess.run(["open", str(dest)], check=False)
                    elif sys.platform.startswith("linux"):
                        subprocess.run(["xdg-open", str(dest)], check=False)
                except Exception:
                    pass


def run_gui():
    # Minimal Tkinter GUI using stdlib only
    import tkinter as tk
    from tkinter import ttk, messagebox

    root = tk.Tk()
    root.title("Webtoon Grabber → samples_in/")
    root.geometry("720x200")

    url_var = tk.StringVar()
    out_var = tk.StringVar(value="samples_in")

    frm = ttk.Frame(root, padding=12)
    frm.pack(fill=tk.BOTH, expand=True)

    ttk.Label(frm, text="Webtoon URL:").grid(row=0, column=0, sticky=tk.W)
    url_entry = ttk.Entry(frm, textvariable=url_var, width=90)
    url_entry.grid(row=0, column=1, sticky=tk.EW)
    url_entry.focus_set()

    ttk.Label(frm, text="Output Folder:").grid(row=1, column=0, sticky=tk.W)
    out_entry = ttk.Entry(frm, textvariable=out_var, width=40)
    out_entry.grid(row=1, column=1, sticky=tk.W)

    pb = ttk.Progressbar(frm, mode="determinate")
    pb.grid(row=2, column=0, columnspan=2, sticky=tk.EW, pady=(12, 6))

    log = tk.Text(frm, height=5)
    log.grid(row=3, column=0, columnspan=2, sticky=tk.NSEW)

    frm.columnconfigure(1, weight=1)
    frm.rowconfigure(3, weight=1)

    def append(msg: str):
        log.insert(tk.END, msg + "\n")
        log.see(tk.END)
        root.update_idletasks()

    def on_download():
        url = url_var.get().strip()
        out = out_var.get().strip() or "samples_in"
        if not url:
            messagebox.showerror("Error", "Please paste a URL")
            return
        try:
            # Normalize URL to mobile if needed
            nu, changed = normalize_naver_url(url)
            if changed:
                append(f"[info] Rewriting to mobile page for better image access: {nu}")
            append(f"[1/3] Fetching page: {nu}")
            raw = fetch(nu, referer=nu, binary=True)
            html = raw.decode("utf-8", errors="ignore")
            append("[2/3] Parsing image URLs")
            urls = extract_image_urls(html, base=nu)
            append(f"  Found {len(urls)} candidate images")
            if not urls:
                messagebox.showwarning("No images", "No images found. Try a mobile page URL (m.comic.naver.com)")
                return
            pb.configure(maximum=len(urls), value=0)
            saved = []
            dest = Path(out)
            for i, u in enumerate(urls, 1):
                name = f"{i:03d}{infer_ext(u)}"
                try:
                    data = fetch(u, referer=nu, binary=True)
                    dest.mkdir(parents=True, exist_ok=True)
                    (dest / name).write_bytes(data)
                    saved.append(name)
                    append(f"[ok] {i}/{len(urls)}: {name}")
                except Exception as e:
                    append(f"[warn] failed {i}/{len(urls)}: {e}")
                pb.configure(value=i)
                root.update_idletasks()
            append(f"Done. Saved {len(saved)} images to {dest}/")
            messagebox.showinfo("Done", f"Saved {len(saved)} images to {dest}/")
        except Exception as e:
            messagebox.showerror("Error", str(e))

    btn = ttk.Button(frm, text="Download", command=on_download)
    btn.grid(row=1, column=1, sticky=tk.E, padx=(0, 4))

    root.mainloop()


def main(argv: list[str]):
    import argparse

    p = argparse.ArgumentParser(description="Grab images from a Naver Webtoon page into samples_in/")
    p.add_argument("--url", dest="url", help="Webtoon URL")
    p.add_argument("--out", dest="out", default="samples_in", help="Output folder or base folder (default: samples_in). If it equals 'samples_in', a per-chapter subfolder is created.")
    p.add_argument("--gui", action="store_true", help="Launch a tiny Tkinter GUI")
    p.add_argument("--no-hint", action="store_true", help="Do not print the two-pass command hint")
    args = p.parse_args(argv)

    if args.gui:
        return run_gui()
    return run_cli(args.url, args.out, auto_process_hint=not args.no_hint)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
