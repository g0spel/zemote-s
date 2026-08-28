#!/usr/bin/env python3
"""下载 Sarasa Ui/Term SC 并子集化为应用内字体。

产物:assets/fonts/ZemoteS-{UI-Regular,UI-Bold,Term-Regular}.ttf
子集范围:GB2312 全集 + ASCII + 中英标点(spec §3 方案 A)。
字体许可:SIL OFL 1.1(更纱黑体),README 需附许可声明。
版本:v1.0.41(2026-08 核实;执行时若过时,更新 FONT_TAG 即可)。
"""
import subprocess, sys, pathlib, shutil

FONT_TAG = "v1.0.41"
FONT_BASE = ("https://github.com/be5invis/Sarasa-Gothic/releases/"
             f"download/{FONT_TAG}")
# 7z 包(Unhinted:子集化反正丢弃 hinting,包更小)
PACKAGES = {
    "SarasaUiSC-TTF-Unhinted-1.0.41.7z": [
        ("SarasaUiSC-Regular.ttf", "ZemoteS-UI-Regular.ttf"),
        ("SarasaUiSC-Bold.ttf", "ZemoteS-UI-Bold.ttf"),
    ],
    "SarasaTermSC-TTF-Unhinted-1.0.41.7z": [
        ("SarasaTermSC-Regular.ttf", "ZemoteS-Term-Regular.ttf"),
    ],
}
OUT = pathlib.Path("assets/fonts")
TMP = pathlib.Path("build/_fonts")
OUT.mkdir(parents=True, exist_ok=True)

# GB2312 全集
def gb2312_chars() -> str:
    chars = []
    for hi in range(0xA1, 0xF8):
        for lo in range(0xA1, 0xFF):
            try:
                chars.append(bytes([hi, lo]).decode("gb2312"))
            except UnicodeDecodeError:
                pass
    return "".join(chars)

UNICODE_RANGES = (
    "U+0020-007E,U+00A0-00FF,U+2000-206F,"
    "U+3000-303F,U+FF00-FFEF,U+2460-24FF"
)

def main():
    if shutil.which("7z") is None:
        sys.exit("需要 7z(pacman -S p7zip)")
    textfile = OUT / "subset-chars.txt"
    textfile.write_text(gb2312_chars(), encoding="utf-8")
    for pkg, picks in PACKAGES.items():
        archive = TMP / pkg
        if not archive.exists():
            print(f"downloading {pkg} …")
            archive.parent.mkdir(parents=True, exist_ok=True)
            urllib.request.urlretrieve(f"{FONT_BASE}/{pkg}", archive)
        extract_dir = TMP / pkg.removesuffix(".7z")
        if not extract_dir.exists():
            subprocess.run(["7z", "x", str(archive), f"-o{extract_dir}"],
                           check=True, capture_output=True)
        for src_name, dst_name in picks:
            found = list(extract_dir.rglob(src_name))
            assert found, f"{src_name} 不在包内"
            out = OUT / dst_name
            subprocess.run([
                sys.executable, "-m", "fontTools.subset", str(found[0]),
                f"--text-file={textfile}",
                f"--unicodes={UNICODE_RANGES}",
                "--layout-features=*", f"--output-file={out}",
            ], check=True)
            print(f"{out} : {out.stat().st_size/1e6:.1f} MB")

if __name__ == "__main__":
    import urllib.request
    main()
