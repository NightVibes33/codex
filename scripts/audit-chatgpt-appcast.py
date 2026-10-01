#!/usr/bin/env python3
import urllib.request, xml.etree.ElementTree as ET

URL="https://persistent.oaistatic.com/codex-app-prod/appcast-x64.xml"
req=urllib.request.Request(URL, headers={"User-Agent":"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_13_6) AppleWebKit/605.1.15"})
data=urllib.request.urlopen(req, timeout=60).read()
print("appcast_bytes=", len(data))
root=ET.fromstring(data)
SPARKLE="{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items=[]
for item in root.findall(".//item"):
    title=(item.findtext("title") or "").strip()
    pub=(item.findtext("pubDate") or "").strip()
    enc=item.find("enclosure")
    if enc is None:
        continue
    attrs=enc.attrib
    url=attrs.get("url","")
    ver=attrs.get(SPARKLE+"shortVersionString","")
    build=attrs.get(SPARKLE+"version","")
    minos=attrs.get(SPARKLE+"minimumSystemVersion","")
    items.append((pub,ver,build,minos,url,title))
print("items=",len(items))
for row in items[:200]:
    print("\t".join(row))
