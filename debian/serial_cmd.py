#!/usr/bin/env python3
# Drive the USB serial console of the tablet non-interactively (event-driven).
import os, sys, time, termios, select, re, glob, argparse

ap = argparse.ArgumentParser()
ap.add_argument("cmd", nargs="*")
ap.add_argument("--dev", default="/dev/ttyACM0")
ap.add_argument("--user", default="nabu")
ap.add_argument("--passwd", default="nabu")
ap.add_argument("--read", type=float, default=25.0)
args = ap.parse_args()
cmd = " ".join(args.cmd) if args.cmd else "id"

DEV = args.dev
if not os.path.exists(DEV):
    cands = sorted(glob.glob("/dev/ttyACM*") + glob.glob("/dev/ttyUSB*"))
    if cands:
        DEV = cands[0]
print(f"# using {DEV}", file=sys.stderr)

ANSI = re.compile(rb'\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][0-9A-Za-z]|\r')

def open_serial(dev):
    fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = 0
    a[1] = 0
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[3] = 0
    a[4] = termios.B115200
    a[5] = termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd

def drain(fd, t):
    end = time.time() + t
    buf = b""
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                d = os.read(fd, 8192)
            except OSError:
                break
            if d:
                buf += d
    return buf

def expect(fd, pats, timeout):
    buf = b""
    end = time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                d = os.read(fd, 8192)
            except OSError:
                break
            if d:
                buf += d
                for p in pats:
                    if p in buf:
                        return p, buf
    return None, buf

def send(fd, s):
    os.write(fd, s.encode())

fd = open_serial(DEV)
drain(fd, 0.3)

# Get to a shell prompt, logging in if needed.  Opening/closing ttyGS0 makes
# g_serial WARN and the register dump floods the console ahead of the getty
# prompt, and an empty line does not always make getty reprint, so first wait
# for a prompt that is already on screen and only then poke the console.
logged_in = False
for attempt in range(25):
    p, out = expect(fd, [b"login:", b"Password:", b"$ ", b"# "], 2)
    if p is None:
        send(fd, "\n")
        p, out = expect(fd, [b"login:", b"Password:", b"$ ", b"# "], 3)
    if p in (b"$ ", b"# "):
        logged_in = True
        break
    if p == b"login:":
        send(fd, args.user + "\n")
        p, out = expect(fd, [b"assword:", b"login:"], 4)
        if p == b"assword:":
            send(fd, args.passwd + "\n")
            p, out = expect(fd, [b"$ ", b"# ", b"Login incorrect"], 6)
            if p in (b"$ ", b"# "):
                logged_in = True
                break
    if p == b"Password:":
        send(fd, args.passwd + "\n")
        p, out = expect(fd, [b"$ ", b"# "], 5)
        if p in (b"$ ", b"# "):
            logged_in = True
            break
if not logged_in:
    print("### could not log in", file=sys.stderr)

send(fd, cmd + "\n")
out = b""
end = time.time() + args.read
while time.time() < end:
    p, chunk = expect(fd, [b"__never__"], 1.0)
    out += chunk
    if b"assword" in chunk and b"sudo" in cmd.encode():
        send(fd, args.passwd + "\n")
    if b"END_MARK" in out:
        break

sys.stdout.write(ANSI.sub(b"", out).decode("utf-8", "replace"))
os.close(fd)
