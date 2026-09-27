#!/usr/bin/env python3
"""
Patch amap_flutter_location 3.0.0 (iOS) to build against AMapLocation 2.9.0.

Background: AMapLocation SDK versions >= 2.10.0 are NOT published on the public
CocoaPods trunk (latest there is 2.9.0). The plugin 3.0.0 calls
setReGeocodeLanguage: which only exists in >= 2.10.0, causing
"Use of undeclared identifier 'AMapLocationReGeocodeLanguageDefault'" errors.

Fix: comment out the geoLanguage block in AMapFlutterLocationPlugin.m.
Re-geocode language then falls back to the SDK default (Chinese), which is
what this app uses anyway. Idempotent: safe to run multiple times.
"""
import glob
import os
import sys

PATTERN_OLD = '''    NSNumber *geoLanguage = call.arguments[@"geoLanguage"];
    if (geoLanguage) {
        if ([geoLanguage integerValue] == 0) {
            [manager setReGeocodeLanguage:AMapLocationReGeocodeLanguageDefault];
        } else if ([geoLanguage integerValue] == 1) {
            [manager setReGeocodeLanguage:AMapLocationReGeocodeLanguageChinse];
        } else if ([geoLanguage integerValue] == 2) {
            [manager setReGeocodeLanguage:AMapLocationReGeocodeLanguageEnglish];
        }
    }
'''

PATTERN_NEW = '''    // PATCHED for AMapLocation 2.9.0 (CocoaPods trunk latest, lacks
    // setReGeocodeLanguage API added in 2.10.0). SDK default language is fine.
    // NSNumber *geoLanguage = call.arguments[@"geoLanguage"];
    // if (geoLanguage) {
    //     if ([geoLanguage integerValue] == 0) {
    //         [manager setReGeocodeLanguage:AMapLocationReGeocodeLanguageDefault];
    //     } else if ([geoLanguage integerValue] == 1) {
    //         [manager setReGeocodeLanguage:AMapLocationReGeocodeLanguageChinse];
    //     } else if ([geoLanguage integerValue] == 2) {
    //         [manager setReGeocodeLanguage:AMapLocationReGeocodeLanguageEnglish];
    //     }
    // }
'''

MARKER = "// PATCHED for AMapLocation 2.9.0"


def main() -> int:
    candidates = glob.glob(os.path.expanduser(
        "~/.pub-cache/hosted/pub.dev/amap_flutter_location-*/ios/Classes/AMapFlutterLocationPlugin.m"
    )) + glob.glob(os.path.expanduser(
        "~/.pub-cache/git/amap_flutter_location*/ios/Classes/AMapFlutterLocationPlugin.m"
    ))
    if not candidates:
        print("patch_amap_ios: no AMapFlutterLocationPlugin.m found under pub-cache", file=sys.stderr)
        return 1

    failed = False
    for path in candidates:
        with open(path, "r", encoding="utf-8") as f:
            src = f.read()
        if MARKER in src:
            print(f"patch_amap_ios: already patched: {path}")
            continue
        if PATTERN_OLD not in src:
            print(f"patch_amap_ios: expected block not found in {path}; plugin updated?", file=sys.stderr)
            failed = True
            continue
        with open(path, "w", encoding="utf-8") as f:
            f.write(src.replace(PATTERN_OLD, PATTERN_NEW, 1))
        print(f"patch_amap_ios: patched {path}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
