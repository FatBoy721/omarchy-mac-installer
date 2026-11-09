# SPDX-License-Identifier: MIT
"""Centauri firmware preparation from the installer's selected restore identity.

FTAB/IM4M parsing adapted from Rolando's mk-ftab-w3.py at
rolotrealanis98/m5pro-linux 1381edf028814b08c2783da6d5b0fa15ba2a80db.
This checks identity/digests, not an independently anchored Apple signature.

MIT License

Copyright (c) 2026 Rolando (github.com/rolotrealanis98)

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
"""
import hashlib
import re
import struct

MAX_DRIVER = 64 << 20
MAX_TICKET = 1 << 20


class CentauriError(ValueError):
    pass


def die(message):
    raise CentauriError(message)


def ftab_parse(d, what):
    if len(d) < 0x30 or d[0x20:0x28] != b"rkosftab":
        die(f"{what}: no rkosftab magic at 0x20")
    hdr = struct.unpack_from("<8I", d, 0)
    n, unk6 = struct.unpack_from("<2I", d, 0x28)
    table_end = 0x30 + 16 * n
    if not 0 < n < 1024 or table_end > len(d):
        die(f"{what}: entry count {n} does not fit")
    ents, ranges = [], []
    for i in range(n):
        tag, off, size, unk = struct.unpack_from("<4sIII", d, 0x30 + 16 * i)
        if off < table_end or off + size > len(d):
            die(f"{what}: entry {i} {tag!r} 0x{off:x}+0x{size:x} out of bounds")
        ents.append((tag, off, size, unk))
        ranges.append((off, off + size))
    ranges.sort()
    for (a0, a1), (b0, b1) in zip(ranges, ranges[1:]):
        if b0 < a1:
            die(f"{what}: overlapping entries at 0x{b0:x}")
    tags = [e[0] for e in ents]
    if len(set(tags)) != len(tags):
        die(f"{what}: duplicate tags")
    return dict(hdr=hdr, n=n, unk6=unk6, ents=ents, table_end=table_end,
                data_end=max(r[1] for r in ranges), tkt_off=hdr[4], tkt_len=hdr[5])


# ---------------------------------------------------------------- DER (just enough for IM4M)
def der(b, i):
    """-> (cls_byte, tagnum, value_start, value_len). Handles high-tag-number (private 4CC) tags."""
    if not 0 <= i < len(b):
        raise ValueError("truncated DER tag")
    t = b[i]
    i += 1
    num = t & 0x1F
    if num == 0x1F:
        num = 0
        while True:
            if i >= len(b) or num.bit_length() > 32:
                raise ValueError("invalid DER tag")
            c = b[i]
            i += 1
            num = (num << 7) | (c & 0x7F)
            if not c & 0x80:
                break
    if i >= len(b):
        raise ValueError("truncated DER length")
    L = b[i]
    i += 1
    if L & 0x80:
        k = L & 0x7F
        if not 0 < k <= 4:
            raise ValueError("bad DER length")
        if i + k > len(b):
            raise ValueError("truncated DER length")
        L = int.from_bytes(b[i:i + k], "big")
        i += k
    if i + L > len(b):
        raise ValueError("DER element runs past its container")
    return t, num, i, L


def children(b, start, length):
    i, end = start, start + length
    while i < end:
        t, num, v, L = der(b, i)
        if v + L > end:
            raise ValueError("DER child crosses container")
        yield t, num, v, L
        i = v + L
    if i != end:
        raise ValueError("DER children overrun")


def fourcc(num):
    return num.to_bytes(4, "big") if num.bit_length() <= 32 else b"????"


def im4m_parse(b):
    """-> dict: manp {key: (type, value)} and images {tag: {key: (type, value)}}.
    Values are kept in memory for the checks only; nothing here is printed except key names."""
    t, _, v, L = der(b, 0)
    if t != 0x30 or v + L != len(b):
        die("IM4M: not one DER SEQUENCE spanning the file")
    top = list(children(b, v, L))
    if len(top) < 4 or top[0][0] != 0x16 or b[top[0][2]:top[0][2] + top[0][3]] != b"IM4M":
        die("IM4M: no 'IM4M' header")
    if top[2][0] != 0x31:
        die("IM4M: no manifest body SET")
    if top[3][0] != 0x04:
        die("IM4M: no signature OCTET STRING")

    def props(start, length):
        out = {}
        for t, num, v, L in children(b, start, length):
            if t & 0xE0 != 0xE0:  # private, constructed [4CC]
                raise ValueError("unexpected element in a property set")
            (st, _, sv, sl), = [c for c in children(b, v, L)]
            parts = list(children(b, sv, sl))
            name = b[parts[0][2]:parts[0][2] + parts[0][3]]
            if name != fourcc(num):
                raise ValueError("property name mismatch")
            pt, _, pv, pl = parts[1]
            if name in out:
                raise ValueError("duplicate manifest property")
            out[name] = (pt, b[pv:pv + pl], pv, pl)
        return out

    manb = None
    for t, num, v, L in children(b, top[2][2], top[2][3]):
        if fourcc(num) == b"MANB":
            if manb is not None:
                raise ValueError("duplicate MANB")
            manb = (v, L)
    if manb is None:
        die("IM4M: no MANB")
    (st, _, sv, sl), = list(children(b, *manb))
    seq = list(children(b, sv, sl))
    if b[seq[0][2]:seq[0][2] + seq[0][3]] != b"MANB" or seq[1][0] != 0x31:
        die("IM4M: malformed MANB")
    manp, images = None, {}
    for t, num, v, L in children(b, seq[1][2], seq[1][3]):
        (st2, _, sv2, sl2), = list(children(b, v, L))
        inner = list(children(b, sv2, sl2))
        name = b[inner[0][2]:inner[0][2] + inner[0][3]]
        if name != fourcc(num) or inner[1][0] != 0x31:
            die("IM4M: malformed MANB entry")
        p = props(inner[1][2], inner[1][3])
        if name == b"MANP":
            if manp is not None:
                raise ValueError("duplicate MANP")
            manp = p
        else:
            if name in images:
                raise ValueError("duplicate manifest image")
            images[name] = p
    if manp is None:
        die("IM4M: no MANP")
    return manp, images


def as_int(p, k):
    t, val, _, _ = p[k]
    if t != 0x02:
        die(f"IM4M: MANP {k.decode()} is not an INTEGER")
    return int.from_bytes(val, "big")


def as_bool(p, k):
    t, val, _, _ = p[k]
    if t != 0x01 or val not in (b"\0", b"\xff"):
        die(f"IM4M: MANP {k.decode()} is not a BOOLEAN")
    return val[0] != 0



def _number(value):
    if type(value) is int:
        return value
    if isinstance(value, str):
        return int(value, 0)
    raise CentauriError("invalid restore identity number")


def _read(installer, path, limit):
    if not isinstance(path, str) or path.startswith("/") or any(
        part in ("", ".", "..") for part in path.split("/")
    ):
        raise CentauriError("invalid restore member path")
    with installer.open(path) as member:
        data = member.read(limit + 1)
    if not data or len(data) > limit:
        raise CentauriError("restore member is empty or exceeds limit")
    return data


def prepare(installer):
    """Return normal FWPackage (name, bytes), or None for a legacy board.

    The caller already selected and loaded its restore BuildIdentity. Reads
    use that StubInstaller's existing ZIP/cache, never another firmware URL.
    """
    sysinfo = getattr(installer, "sysinfo", None)
    if getattr(sysinfo, "device_class", "") != "j714sap":
        return None
    try:
        identity = installer.identity
        info = identity["Info"]
        manifest = installer.manifest
        if (sysinfo.chip_id != 0x6050 or sysinfo.board_id != 0x08
                or info["DeviceClass"] != sysinfo.device_class
                or _number(identity["ApChipID"]) != sysinfo.chip_id
                or _number(identity["ApBoardID"]) != sysinfo.board_id
                or info["Variant"] != "macOS Customer"
                or info["BuildNumber"] != manifest["ProductBuildVersion"]):
            raise CentauriError("Centauri selected restore identity mismatch")
        target = sysinfo.get_str(sysinfo.dt["target-type"]).lower()
        if not re.fullmatch(r"[a-z0-9]{1,15}", target):
            raise CentauriError("invalid Centauri ADT target-type")
        wireless_chip = _number(identity["Wireless1,ChipID"])
        wireless_board = _number(identity["Wireless1,BoardID"])
        if wireless_chip != 0x2026:
            raise CentauriError("unsupported Centauri accessory chip")
        components = [entry for key, entry in identity["Manifest"].items()
                      if key.startswith("Wireless1,")]
        if not components or any(entry.get("Trusted") is not True for entry in components):
            raise CentauriError("missing trusted Wireless1 components")
        paths = {entry["Info"]["Path"] for entry in components}
        if len(paths) != 1 or any(entry["Info"].get("IsFTAB") is not True for entry in components):
            raise CentauriError("Wireless1 components do not share one FTAB")
        data = _read(installer, paths.pop(), MAX_DRIVER)
        ticket_path = ("Firmware/Manifests/restore/macOS Customer/centauri/centauri."
                       + sysinfo.device_class + ".im4m")
        ticket = _read(installer, ticket_path, MAX_TICKET)
        ftab = ftab_parse(data, "input FTAB")
        if (any(ftab["hdr"][i] for i in range(2, 8)) or ftab["unk6"]
                or ftab["data_end"] != len(data) or len(data) % 4):
            raise CentauriError("unsupported or already ticketed FTAB")
        manp, images = im4m_parse(ticket)
        if any(key in manp for key in (b"ECID", b"BNCH", b"snon", b"Nonc")):
            raise CentauriError("personalized Centauri ticket is not supported")
        if (as_int(manp, b"CHIP") != wireless_chip
                or as_int(manp, b"BORD") != wireless_board
                or not as_bool(manp, b"CPRO") or not as_bool(manp, b"CSEC")):
            raise CentauriError("Centauri production ticket/accessory identity mismatch")
        expected = sorted(entry["Digest"] for entry in components)
        if any(properties[b"DGST"][0] != 0x04 for properties in images.values()):
            raise CentauriError("Centauri digest is not an OCTET STRING")
        actual = sorted(properties[b"DGST"][1] for properties in images.values())
        if not actual or expected != actual or any(len(digest) != 48 for digest in actual):
            raise CentauriError("Wireless1/ticket digest sets differ")
        entries = {entry[0]: entry for entry in ftab["ents"]}
        for tag, properties in images.items():
            _, offset, size, _ = entries[tag]
            if hashlib.sha384(data[offset:offset + size]).digest() != properties[b"DGST"][1]:
                raise CentauriError("Centauri FTAB segment digest mismatch")
        result = bytearray(data)
        struct.pack_into("<II", result, 0x10, len(data), len(ticket))
        result.extend(ticket)
        if len(result) > MAX_DRIVER:
            raise CentauriError("ticketed Centauri FTAB exceeds driver limit")
        return "apple/centauri/" + target + "-ftab.bin", bytes(result)
    except CentauriError:
        raise
    except (KeyError, IndexError, TypeError, ValueError, AttributeError, OSError, struct.error) as error:
        raise CentauriError("invalid Centauri restore inputs") from error


def collect(installer, package):
    """Add prepared bytes to the existing private vendor archive, no files/logs."""
    item = prepare(installer)
    if item is not None:
        import asahi_firmware
        name, data = item
        package.add_file(name, asahi_firmware.core.FWFile(name, data))
