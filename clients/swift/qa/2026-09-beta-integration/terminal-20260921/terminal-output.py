import sys
sys.stdout.buffer.write(b"\r\nQA-BURST-BEGIN\r\n")
for i in range(65536):
    sys.stdout.buffer.write((f"{i:06d}|" + "x" * 72 + "\n").encode())
sys.stdout.buffer.write(b"\r\nQA-BURST-END\r\n")
sys.stdout.buffer.flush()
