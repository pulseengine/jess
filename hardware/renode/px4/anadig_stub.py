# ANADIG (0x40C8_0000) stub for PX4 RT1176 boot: DIGPROG silicon-rev at +0x800
# returns the RT1176 value 0x001170A0 (the ROM_API_Init / ClearCache chip-version
# gate); all other offsets flip-flop (0 / 0xFFFFFFFF) so clock lock/ready polls pass.
if request.IsInit:
    lastVal = 0
elif request.IsRead:
    if request.Offset == 0x800:
        request.Value = 0x001170A0
    else:
        lastVal = 0xFFFFFFFF - lastVal
        request.Value = lastVal
