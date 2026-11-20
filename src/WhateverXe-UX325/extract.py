"""Copy the UX325EA functions out of WhateverXe/kern_xe.cpp for the unit-test harnesses.
usage: python3 extract.py kern_xe.cpp out.inc [timing|all]
  timing  link-rate/lane clamp + display-timing rescue (harness.cpp)
  all     the above + OLED brightness (test4/harness4.cpp)"""
import sys
src = open(sys.argv[1]).read()
mode = sys.argv[3] if len(sys.argv) > 3 else 'timing'
a = src.index('static uint64_t tglLinkRateHz(uint32_t code) {')
end = '// Max luminance (nits) from the panel' if mode == 'timing' else 'uint32_t XE::wrapTGLDPPower(void *port, uint8_t state) {'
b = src.index(end, a)
open(sys.argv[2], 'w').write(src[a:b])
