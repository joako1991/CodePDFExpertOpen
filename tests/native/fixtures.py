# SPDX-License-Identifier: AGPL-3.0-or-later
def pdf_fixture(path, *, rotated=False, nested=False):
    def stream(data, extra=b""):
        return b"<< /Length %d %s >>\nstream\n" % (len(data), extra) + data + b"\nendstream"
    boxes = b"/Rotate 90 /CropBox [20 30 575 810]" if rotated else b""
    graphics = b"q 80 0 0 80 50 540 cm /Im0 Do Q\nq 80 0 0 80 150 540 cm /Im0 Do Q\n"
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources 9 0 R /Contents 5 0 R " + boxes + b" >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources 9 0 R /Contents 6 0 R >>",
        stream(b"BT /F1 18 Tf 50 740 Td (ORIGINAL_SECRET) Tj ET\nBT /F1 18 Tf 50 680 Td (KEEP_LINE) Tj ET\n" + (b"q /Fm0 Do Q\n" if nested else graphics)),
        stream(b"BT /F1 18 Tf 50 740 Td (SECOND_PAGE) Tj ET\n" + graphics),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        stream(bytes([255, 0, 0]) * 16, b"/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceRGB /BitsPerComponent 8"),
        b"<< /Font << /F1 7 0 R >> /XObject << /Im0 8 0 R /Fm0 10 0 R >> >>",
        stream(graphics, b"/Type /XObject /Subtype /Form /BBox [0 0 595 842] /Resources << /XObject << /Im0 8 0 R >> >>"),
    ]
    data = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data += f"{index} 0 obj\n".encode() + obj + b"\nendobj\n"
    start = len(data)
    data += f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode()
    for offset in offsets[1:]: data += f"{offset:010d} 00000 n \n".encode()
    data += f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n".encode()
    path.write_bytes(data)
