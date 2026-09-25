#!/usr/bin/env python3
"""Fetches the Material Symbols that Flux for Android uses.

The icons are the Rounded style at the 24 dp optical size, from
github.com/google/material-design-icons, under the Apache License 2.0.
Each icon becomes res/drawable/ic_<name>.xml. A name that ends in "+fill"
also gets the filled variant as ic_<name>_fill.xml.

Usage: tools/fetch_icons.py
"""

import pathlib
import re
import sys
import urllib.error
import urllib.request

ICONS = """
add arrow_back arrow_upward chevron_right close check check_circle
content_copy content_paste content_paste_go delete download error info
key link link_off more_vert open_in_new refresh search send settings sync
tune warning

smartphone desktop_windows tablet tv computer
wifi wifi_off wifi_find
battery_full battery_6_bar battery_5_bar battery_4_bar battery_3_bar
battery_2_bar battery_1_bar battery_0_bar battery_charging_full

upload_file photo_camera music_note terminal folder_open ring_volume
notifications notifications_active call

skip_previous+fill skip_next+fill play_arrow+fill pause+fill

folder+fill draft description image movie audio_file picture_as_pdf
folder_zip code home hard_drive

text_fields qr_code_scanner document_scanner videocam+fill videocam_off
cameraswitch flash_on flash_off flash_auto rotate_right stop+fill
fiber_manual_record+fill photo_library do_not_disturb_on screenshot
mic+fill mic_off screen_share stop_screen_share

fingerprint power_settings_new
""".split()

BASE = "https://raw.githubusercontent.com/google/material-design-icons/master/symbols/android"


def fetch(name: str, fill: bool) -> str:
    suffix = "_fill1_24px.xml" if fill else "_24px.xml"
    url = f"{BASE}/{name}/materialsymbolsrounded/{name}{suffix}"
    with urllib.request.urlopen(url, timeout=30) as r:
        xml = r.read().decode()
    # Compose tints the icon with the content color, so the theme tint goes.
    return re.sub(r'\s*android:tint="[^"]*"', "", xml)


def main() -> int:
    out = pathlib.Path(__file__).resolve().parent.parent / "app/src/main/res/drawable"
    out.mkdir(parents=True, exist_ok=True)
    missing = []
    for entry in ICONS:
        name, _, variant = entry.partition("+")
        try:
            (out / f"ic_{name}.xml").write_text(fetch(name, fill=False))
            if variant == "fill":
                (out / f"ic_{name}_fill.xml").write_text(fetch(name, fill=True))
        except urllib.error.HTTPError as e:
            missing.append(f"{entry} ({e.code})")
    print(f"wrote {len(ICONS) - len(missing)} icons to {out}")
    if missing:
        print("missing:", ", ".join(missing), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
