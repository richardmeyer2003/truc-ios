"""Structural checks available on Windows/Linux before spending macOS build time."""
from pathlib import Path
import json
import plistlib
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
native = root / 'ios/App/App'
info = plistlib.loads((native / 'Info.plist').read_bytes())
assert info['CFBundleDisplayName'] == 'TURC'
assert 'NSAppTransportSecurity' not in info, 'Do not weaken TLS for the hosted backend'
config = json.loads((root / 'capacitor.config.json').read_text())
assert config['appId'] == 'org.turc.clubhouse'
assert 'server' not in config, 'The app must bundle its frontend'
project = (root / 'ios/App/App.xcodeproj/project.pbxproj').read_text()
assert 'TURCNative.swift in Sources' in project
assert 'TURCViewController()' in (native / 'SceneDelegate.swift').read_text()
tree = ET.parse(native / 'Base.lproj/Main.storyboard')
assert tree.find('.//viewController').attrib['customClass'] == 'TURCViewController'
ET.parse(native / 'Base.lproj/LaunchScreen.storyboard')
for item in (native / 'Assets.xcassets').rglob('Contents.json'):
    json.loads(item.read_text())
print('Native project structure checks passed (Xcode compilation remains a macOS CI check).')
