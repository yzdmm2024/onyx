#!/usr/bin/env python3
import struct, sys, os, io, tarfile

DEB = "com.yzdmm.onyx_0.3.0_iphoneos-arm64.deb"

# --- minimal ar parser ---
with open(DEB, "rb") as f:
    data = f.read()
assert data[:8] == b"!<arch>\n", "not a deb/ar"
off = 8
members = {}
while off < len(data):
    if off + 60 > len(data):
        break
    hdr = data[off:off+60]
    name = hdr[0:16].decode().strip()
    size = int(hdr[48:58].decode().strip())
    off += 60
    content = data[off:off+size]
    members[name] = content
    off += size
    if size % 2 == 1:  # odd-length members padded with newline
        off += 1
print("ar members:", list(members.keys()))

# --- find data tar ---
data_name = [k for k in members if k.startswith("data.tar")][0]
raw = members[data_name]
print("data member:", data_name, "bytes:", len(raw))

# decompress
if data_name.endswith(".xz") or data_name.endswith(".lzma"):
    import lzma
    tar_bytes = lzma.decompress(raw)
elif data_name.endswith(".gz"):
    import gzip
    tar_bytes = gzip.decompress(raw)
else:
    tar_bytes = raw
print("tar bytes:", len(tar_bytes))

tf = tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:")
app_bin = None
for m in tf.getmembers():
    if m.name.endswith("OnyxApp") and m.isfile():
        app_bin = tf.extractfile(m).read()
        print("found OnyxApp binary:", m.name, "size:", len(app_bin))
        break
if app_bin is None:
    print("OnyxApp binary NOT found in deb!")
    sys.exit(2)

# --- extract embedded entitlements (search plist xml) ---
idx = app_bin.find(b"<?xml")
if idx == -1:
    idx = app_bin.find(b"<plist")
if idx == -1:
    print("NO embedded plist found in binary (entitlements likely missing!)")
    sys.exit(3)
end = app_bin.find(b"</plist>", idx)
if end == -1:
    print("plist start found but no close tag")
    sys.exit(3)
plist = app_bin[idx:end+len(b"</plist>")]
text = plist.decode("utf-8", "replace")
print("\n===== EMBEDDED ENTITLEMENTS =====")
print(text)

# --- key checks ---
checks = [
    b"platform-application",
    b"com.apple.locationd.simulation",
    b"container-required",
    b"get-task-allow",
    b"com.apple.security.network.client",
]
print("\n===== ENTITLEMENT CHECKS =====")
for c in checks:
    print(f"  {'OK ' if c in plist else 'MISSING'} {c.decode()}")
