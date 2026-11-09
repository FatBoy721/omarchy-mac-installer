# SPDX-License-Identifier: MIT
"""Synthetic restore fixtures contain no Apple firmware or ticket material."""
import hashlib
import io
import struct
import unittest
from types import SimpleNamespace

import omarchy_centauri as c


def der(tag, data):
    size = len(data)
    length = bytes([size]) if size < 128 else bytes([0x82]) + size.to_bytes(2, 'big')
    return tag + length + data


def tagged(name, data):
    number = int.from_bytes(name, 'big')
    parts = [number & 127]
    number >>= 7
    while number:
        parts.insert(0, (number & 127) | 128)
        number >>= 7
    return der(b'\xff' + bytes(parts), der(b'\x30', der(b'\x16', name) + data))


def ticket(digest, board=0x841, chip=0x2026, personalized=False, production=True):
    properties = tagged(b'CHIP', der(b'\x02', chip.to_bytes(2, 'big')))
    properties += tagged(b'BORD', der(b'\x02', board.to_bytes(2, 'big')))
    properties += tagged(b'CPRO', der(b'\x01', b'\xff' if production else b'\0'))
    properties += tagged(b'CSEC', der(b'\x01', b'\xff'))
    if personalized:
        properties += tagged(b'ECID', der(b'\x02', b'\x01'))
    body = tagged(b'MANP', der(b'\x31', properties))
    body += tagged(b'krnl', der(b'\x31', tagged(b'DGST', der(b'\x04', digest))))
    return der(b'\x30', der(b'\x16', b'IM4M') + der(b'\x02', b'\0')
               + der(b'\x31', tagged(b'MANB', der(b'\x31', body))) + der(b'\x04', b'fixture'))


def fixture(**ticket_options):
    payload = b'synthetic-kernel'
    payload += b'\0' * (-len(payload) % 4)
    digest = hashlib.sha384(payload).digest()
    data = struct.pack('<8I', 0, 0, 0, 0, 0, 0, 0, 0) + b'rkosftab'
    data += struct.pack('<II', 1, 0) + struct.pack('<4sIII', b'krnl', 0x40, len(payload), 0) + payload
    identity = {'ApChipID': '0x6050', 'ApBoardID': '0x08',
                'Wireless1,ChipID': 0x2026, 'Wireless1,BoardID': 0x841,
                'Info': {'DeviceClass': 'j714sap', 'Variant': 'macOS Customer', 'BuildNumber': 'fixture'},
                'Manifest': {'Wireless1,Kernel': {'Trusted': True, 'Digest': digest,
                    'Info': {'Path': 'Firmware/ftab.bin', 'IsFTAB': True}}}}
    files = {'Firmware/ftab.bin': data,
             'Firmware/Manifests/restore/macOS Customer/centauri/centauri.j714sap.im4m': ticket(digest, **ticket_options)}
    system = SimpleNamespace(device_class='j714sap', chip_id=0x6050, board_id=8,
                dt={'target-type': b'J714s\0'}, get_str=lambda value:value.rstrip(b'\0').decode())
    instance = SimpleNamespace(sysinfo=system, identity=identity,
                manifest={'ProductBuildVersion': 'fixture'}, reads=[])
    def read(path):
        instance.reads.append(path)
        return io.BytesIO(files[path])
    instance.open = read
    return instance, files


class CentauriTests(unittest.TestCase):
    def test_exact_selected_restore_identity_stitches_only_ticket_fields(self):
        installer, files = fixture()
        name, output = c.prepare(installer)
        data = files['Firmware/ftab.bin']
        manifest = next(value for key, value in files.items() if key.endswith('.im4m'))
        self.assertEqual(name, 'apple/centauri/j714s-ftab.bin')
        self.assertEqual(output[:0x10], data[:0x10])
        self.assertEqual(output[0x18:len(data)], data[0x18:])
        self.assertEqual(struct.unpack_from('<II', output, 0x10), (len(data), len(manifest)))
        self.assertEqual(output[len(data):], manifest)
        self.assertEqual(set(installer.reads), set(files))

    def test_legacy_board_performs_no_restore_reads(self):
        installer, _ = fixture()
        installer.sysinfo.device_class = 'j314sap'
        self.assertIsNone(c.prepare(installer))
        self.assertEqual(installer.reads, [])

    def test_accessory_identity_is_independent_of_ap_board(self):
        for options in ({'board': 8}, {'chip': 0x6050}, {'personalized': True}, {'production': False}):
            with self.subTest(options=options), self.assertRaises(c.CentauriError):
                c.prepare(fixture(**options)[0])

    def test_wrong_selected_identity_rejects_before_firmware_reads(self):
        for key, value in [('ApBoardID','0x0c'), ('ApChipID','0x6051')]:
            installer, _ = fixture()
            installer.identity[key] = value
            with self.subTest(key=key), self.assertRaises(c.CentauriError):
                c.prepare(installer)
            self.assertEqual(installer.reads, [])

    def test_component_and_segment_digest_mismatch_rejected(self):
        installer, _ = fixture()
        installer.identity['Manifest']['Wireless1,Kernel']['Digest'] = bytes(48)
        with self.assertRaises(c.CentauriError):
            c.prepare(installer)
        installer, files = fixture()
        files['Firmware/ftab.bin'] = files['Firmware/ftab.bin'][:-1] + b'x'
        with self.assertRaises(c.CentauriError):
            c.prepare(installer)

    def test_bad_bounds_and_existing_ticket_are_rejected(self):
        for offset, value in [(0x10, 64), (0x28, 1024), (0x34, 0), (0x38, 10000)]:
            installer, files = fixture()
            data = bytearray(files['Firmware/ftab.bin'])
            struct.pack_into('<I', data, offset, value)
            files['Firmware/ftab.bin'] = bytes(data)
            with self.subTest(offset=offset), self.assertRaises(c.CentauriError):
                c.prepare(installer)

    def test_truncated_der_and_unsafe_paths_fail_closed(self):
        installer, files = fixture()
        key = next(key for key in files if key.endswith('.im4m'))
        for size in (1, 3, 20, len(files[key])-1):
            original = files[key]
            files[key] = original[:size]
            with self.subTest(size=size), self.assertRaises(c.CentauriError):
                c.prepare(installer)
            files[key] = original
        installer.identity['Manifest']['Wireless1,Kernel']['Info']['Path'] = '../ftab.bin'
        with self.assertRaises(c.CentauriError):
            c.prepare(installer)


if __name__ == '__main__':
    unittest.main()
