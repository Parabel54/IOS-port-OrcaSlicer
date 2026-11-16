"""Loopback-only peer for the production URLSessionStreamTask smoke test."""
import socket
import sys
from pathlib import Path


def line(connection):
    data = bytearray()
    while not data.endswith(b'\n'):
        part = connection.recv(1)
        if not part or len(data) > 1024:
            raise AssertionError('Missing command terminator')
        data.extend(part)
    return bytes(data)


def acknowledge(connection, detail=b''):
    connection.sendall(detail + b'o')
    connection.sendall(b'k\r\n')


def serve(source):
    expected = Path(source).read_bytes()
    with socket.socket() as server:
        server.bind(('127.0.0.1', 0))
        server.listen(4)
        server.settimeout(15)
        print(server.getsockname()[1], flush=True)
        with server.accept()[0] as connection:
            connection.settimeout(15)
            for command in (b'~M601 S1\r\n', b'~M115\r\n', b'~M650\r\n', b'~M119\r\n'):
                assert line(connection) == command
                acknowledge(connection)
            assert connection.recv(1) == b''
        with server.accept()[0] as connection:
            connection.settimeout(15)
            assert line(connection) == f'~M28 {len(expected)} 0:/user/loopback.gcode\r\n'.encode()
            acknowledge(connection)
            received = bytearray()
            while len(received) < len(expected):
                data = connection.recv(min(4096, len(expected) - len(received)))
                assert data, 'Truncated G-code transfer'
                received.extend(data)
            assert bytes(received) == expected, 'Post-processed bytes changed'
            assert connection.recv(1) == b'', 'Unexpected framing after G-code'
        for command in (b'~M29\r\n', b'~M23 0:/user/loopback.gcode\r\n'):
            with server.accept()[0] as connection:
                connection.settimeout(15)
                assert line(connection) == command
                acknowledge(connection)
                assert connection.recv(1) == b''


if __name__ == '__main__':
    serve(sys.argv[1])
