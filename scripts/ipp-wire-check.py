"""Loopback IPP printer: independent wire decoding, exact upload verification, no real printing."""
import hashlib
import http.server
import pathlib
import socket
import struct
import subprocess
import sys
import tempfile
import threading


def attribute(tag, name, value):
    name = name.encode()
    if isinstance(value, str):
        value = value.encode()
    return bytes([tag]) + struct.pack(">H", len(name)) + name + struct.pack(">H", len(value)) + value


def values(tag, name, items):
    return b"".join(attribute(tag, name if i == 0 else "", value) for i, value in enumerate(items))


def integer(value):
    return struct.pack(">i", value)


def decode(body):
    version, operation, request_id = struct.unpack(">HHI", body[:8])
    assert version == 0x0200
    offset, attrs, name, group = 8, {}, "", 0
    while True:
        tag = body[offset]
        offset += 1
        if tag == 3:
            break
        if tag < 16:
            group = tag
            continue
        n = struct.unpack(">H", body[offset:offset + 2])[0]
        offset += 2
        if n:
            name = body[offset:offset + n].decode()
        offset += n
        n = struct.unpack(">H", body[offset:offset + 2])[0]
        offset += 2
        value = body[offset:offset + n]
        offset += n
        attrs.setdefault(name, []).append((tag, value, group))
    return operation, request_id, attrs, body[offset:]


class Printer(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        assert self.headers["Content-Type"] == "application/ipp"
        assert self.headers.get("Authorization") is None
        body = self.rfile.read(int(self.headers["Content-Length"]))
        operation, request_id, attrs, pdf = decode(body)
        keys = list(attrs)
        assert keys[:3] == ["attributes-charset", "attributes-natural-language", "printer-uri"]
        assert keys[3] == ("job-id" if operation in [6, 8, 9] else "requesting-user-name")
        self.server.operations.append(operation)
        if self.path == "/redirect":
            self.send_response(307)
            self.send_header("Location", "/should-never-follow")
            self.end_headers()
            return
        assert self.path in ["/ipp/print", "/lost-reply"], "Unexpected redirect or resource"
        assert attrs["printer-uri"][0][1].decode().endswith(self.path)
        result = b"\x01" + attribute(0x47, "attributes-charset", "utf-8") + attribute(0x48, "attributes-natural-language", "en")
        if operation == 11:
            assert not pdf
            result += b"\x04"  # printer-attributes-tag (RFC 8010)
            result += attribute(0x49, "document-format-supported", "application/pdf")
            result += values(0x23, "operations-supported", [integer(x) for x in [4, 5, 6, 8, 9]])
            result += attribute(0x44, "media-supported", "iso_a4_210x297mm")
            result += values(0x44, "sides-supported", ["one-sided", "two-sided-long-edge", "two-sided-short-edge"])
            result += values(0x44, "print-color-mode-supported", ["color", "monochrome"])
            result += attribute(0x44, "print-scaling-supported", "none")
            result += attribute(0x22, "printer-is-accepting-jobs", b"\x01")
            result += attribute(0x23, "printer-state", integer(3))
        elif operation in [4, 5]:
            assert not pdf and attrs["ipp-attribute-fidelity"][0][1] == b"\x01"
            for key, expected in [("copies", integer(1)), ("number-up", integer(1)), ("orientation-requested", integer(3)),
                                  ("sides", b"two-sided-long-edge"), ("media", b"iso_a4_210x297mm"), ("print-scaling", b"none")]:
                assert attrs[key][0][1] == expected, (key, attrs[key])
                assert attrs[key][0][2] == 2
            if operation == 5:
                result += b"\x02" + attribute(0x21, "job-id", integer(42))
        elif operation == 6:
            assert attrs["job-id"][0][1] == integer(42)
            assert attrs["document-format"][0][1] == b"application/pdf"
            assert attrs["last-document"][0][1] == b"\x01"
            assert hashlib.sha256(pdf).digest() == self.server.pdf_hash, "Uploaded PDF changed"
            self.server.upload_size = len(pdf)
            if self.path == "/lost-reply":
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
        elif operation == 9:
            result += b"\x02" + attribute(0x23, "job-state", integer(9))
        elif operation == 8:
            assert attrs["job-id"][0][1] == integer(42) and not pdf
        else:
            raise AssertionError(operation)
        response = struct.pack(">HHI", 0x0200, 0, request_id) + result + b"\x03"
        self.send_response(200)
        self.send_header("Content-Type", "application/ipp")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)


def main():
    binary, source = sys.argv[1:]
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Printer)
    server.operations = []
    server.upload_size = 0
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        with tempfile.TemporaryDirectory(prefix="PDFMe-wire-") as folder:
            data = pathlib.Path(source).read_bytes()
            offset = data.rindex(b"startxref")
            large = data[:offset] + b"%" + b"x" * 34_000_000 + b"\n" + data[offset:]
            pdf = pathlib.Path(folder) / "large.pdf"
            pdf.write_bytes(large)
            server.pdf_hash = hashlib.sha256(large).digest()
            endpoint = f"ipp://127.0.0.1:{server.server_port}"
            subprocess.run([binary, "--wire", endpoint + "/ipp/print", str(pdf)], check=True)
            assert server.operations == [11, 4, 5, 6, 9, 8], server.operations
            assert server.upload_size == len(large) > 32_000_000
            print("PASS: PDF over 32 MB is uploaded byte-for-byte with one Send-Document request")
            server.operations = []
            subprocess.run([binary, "--wire", endpoint + "/redirect", str(pdf)], check=True)
            assert server.operations == [11], server.operations
            server.operations = []
            subprocess.run([binary, "--wire", endpoint + "/lost-reply", str(pdf)], check=True)
            assert server.operations == [11, 4, 5, 6], server.operations
            print("PASS: Real connection loss after upload causes no repeated request or fallback")
    finally:
        server.shutdown()
        server.server_close()
    print("HTTP wire checks passed. Only loopback networking was used.")


if __name__ == "__main__":
    main()
