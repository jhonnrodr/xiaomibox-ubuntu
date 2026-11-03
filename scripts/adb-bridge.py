"""Local TCP relay: 127.0.0.1:<local_port> -> <box_ip>:5555.

Workaround for macOS Local Network privacy blocking the adb binary
("No route to host") while other processes can reach the box.
Usage: python3 -I scripts/adb-bridge.py <box_ip> [local_port]
Then:  adb connect 127.0.0.1:<local_port>
"""

import socket
import sys
import threading

ADB_PORT = 5555
DEFAULT_LOCAL_PORT = 15555
BUFFER_SIZE = 65536


def pipe(src: socket.socket, dst: socket.socket) -> None:
    try:
        while data := src.recv(BUFFER_SIZE):
            dst.sendall(data)
    except OSError as exc:
        print(f"relay closed: {exc}", file=sys.stderr)
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(client: socket.socket, box_ip: str) -> None:
    try:
        upstream = socket.create_connection((box_ip, ADB_PORT), timeout=5)
    except OSError as exc:
        print(f"cannot reach {box_ip}:{ADB_PORT}: {exc}", file=sys.stderr)
        client.close()
        return
    upstream.settimeout(None)
    threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
    threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    box_ip = sys.argv[1]
    local_port = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_LOCAL_PORT
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", local_port))
    server.listen()
    print(f"relay 127.0.0.1:{local_port} -> {box_ip}:{ADB_PORT}", flush=True)
    while True:
        client, _ = server.accept()
        handle(client, box_ip)


if __name__ == "__main__":
    main()
