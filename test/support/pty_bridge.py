"""Bridge stdin/stdout to the master side of a fresh pseudo-terminal."""

import errno
import os
import select
import tty


def main():
    master, slave = os.openpty()
    tty.setraw(slave)
    path = os.ttyname(slave)
    os.write(1, f"PTY:{path}\n".encode())

    try:
        while True:
            readable, _, _ = select.select([0, master], [], [])

            if 0 in readable:
                data = os.read(0, 65_536)
                if not data:
                    break
                os.write(master, data)

            if master in readable:
                try:
                    data = os.read(master, 65_536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        continue
                    raise

                if data:
                    os.write(1, data)
    finally:
        os.close(master)
        os.close(slave)


if __name__ == "__main__":
    main()
