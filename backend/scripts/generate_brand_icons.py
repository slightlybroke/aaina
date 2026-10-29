"""Resize the supplied aaina artwork into checked-in platform icons. No new packages."""

import json
from pathlib import Path

from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "frontend/assets/branding/aaina.png"


def main():
    with Image.open(SOURCE) as original:
        artwork = original.convert("RGB")

    def save(path, size, padded=False):
        image = ImageOps.contain(artwork, (size, size), Image.Resampling.LANCZOS)
        if padded:
            image = ImageOps.contain(
                artwork, (round(size * 0.7), round(size * 0.7)), Image.Resampling.LANCZOS
            )
        canvas = Image.new("RGB", (size, size), artwork.getpixel((0, 0)))
        canvas.paste(image, ((size - image.width) // 2, (size - image.height) // 2))
        path.parent.mkdir(parents=True, exist_ok=True)
        canvas.save(path, optimize=True)

    for density, size in {
        "mdpi": 48,
        "hdpi": 72,
        "xhdpi": 96,
        "xxhdpi": 144,
        "xxxhdpi": 192,
    }.items():
        save(ROOT / f"frontend/android/app/src/main/res/mipmap-{density}/ic_launcher.png", size)
    save(ROOT / "frontend/web/favicon.png", 48)
    for size in [192, 512]:
        save(ROOT / f"frontend/web/icons/Icon-{size}.png", size)
        save(ROOT / f"frontend/web/icons/Icon-maskable-{size}.png", size, True)
    icons = ROOT / "frontend/ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for icon in json.loads((icons / "Contents.json").read_text())["images"]:
        if icon.get("filename"):
            size = round(float(icon["size"].split("x")[0]) * float(icon["scale"].rstrip("x")))
            save(icons / icon["filename"], size)
    print("Generated Android, iOS and web icons from the supplied aaina artwork.")


if __name__ == "__main__":
    main()
