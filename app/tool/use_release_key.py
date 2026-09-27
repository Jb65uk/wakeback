#!/usr/bin/env python3
"""Sign release APKs with WakeBack's permanent key, so updates install over the top.

Needs android/key.properties (written by the GitHub build from its secrets, or by you):
    storeFile=upload.jks        (relative to android/app)
    storePassword=...
    keyAlias=wakeback
    keyPassword=...
Patches android/app/build.gradle.kts (or build.gradle) made by `flutter create`. Safe to run twice.
"""
import os, re, sys

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'android', 'app')
kts, groovy = os.path.join(root, 'build.gradle.kts'), os.path.join(root, 'build.gradle')
path = kts if os.path.exists(kts) else groovy
s = open(path).read()
if 'WakeBack release key' in s:
    print('already set up'); sys.exit(0)

if path == kts:
    block = '''    // WakeBack release key (android/key.properties) — the same key for every build
    val wbKeyProps = java.util.Properties().apply {
        val f = rootProject.file("key.properties")
        if (f.exists()) f.inputStream().use { load(it) }
    }
    signingConfigs {
        create("release") {
            if (wbKeyProps.isNotEmpty()) {
                storeFile = file(wbKeyProps.getProperty("storeFile"))
                storePassword = wbKeyProps.getProperty("storePassword")
                keyAlias = wbKeyProps.getProperty("keyAlias")
                keyPassword = wbKeyProps.getProperty("keyPassword")
            }
        }
    }

'''
    old = re.compile(r'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)')
    new = 'signingConfig = if (wbKeyProps.isNotEmpty()) signingConfigs.getByName("release") else signingConfigs.getByName("debug")'
else:
    block = '''    // WakeBack release key (android/key.properties) — the same key for every build
    def wbKeyProps = new Properties()
    def wbKeyFile = rootProject.file("key.properties")
    if (wbKeyFile.exists()) wbKeyFile.withInputStream { wbKeyProps.load(it) }
    signingConfigs {
        release {
            if (!wbKeyProps.isEmpty()) {
                storeFile file(wbKeyProps["storeFile"])
                storePassword wbKeyProps["storePassword"]
                keyAlias wbKeyProps["keyAlias"]
                keyPassword wbKeyProps["keyPassword"]
            }
        }
    }

'''
    old = re.compile(r'signingConfig\s+signingConfigs\.debug')
    new = 'signingConfig wbKeyProps.isEmpty() ? signingConfigs.debug : signingConfigs.release'

m = re.search(r'^(\s*)buildTypes\s*\{', s, re.M)
if not m or not old.search(s):
    sys.exit(f'Could not find buildTypes / the debug signing line in {path} — the Flutter template has changed; tell Claude.')
s = s[:m.start()] + block + s[m.start():]
s = old.sub(new, s, count=1)
open(path, 'w').write(s)
print('release signing set up in', os.path.basename(path))
