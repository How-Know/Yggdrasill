import sys, time, datetime
import serial

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

port = sys.argv[1] if len(sys.argv) > 1 else "COM16"
seconds = int(sys.argv[2]) if len(sys.argv) > 2 else 300

ser = serial.Serial(port, 115200, timeout=1)

# 포트를 열 때 DTR/RTS 상태에 따라 다운로드 모드로 부팅해 버리는 경우가 있어
# IO0을 high로 둔 채 EN만 눌렀다 떼어 항상 정상 부팅시킨다.
ser.dtr = False
ser.rts = True
time.sleep(0.1)
ser.rts = False
time.sleep(0.1)
ser.reset_input_buffer()

end = time.time() + seconds
buf = b""
while time.time() < end:
    chunk = ser.read(4096)
    if not chunk:
        continue
    buf += chunk
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        text = line.decode("utf-8", "replace").rstrip("\r")
        if not text:
            continue
        print(datetime.datetime.now().strftime("%H:%M:%S") + " | " + text, flush=True)
ser.close()
