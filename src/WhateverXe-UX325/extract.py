import sys
src=open(sys.argv[1]).read()
a=src.index('static uint64_t tglLinkRateHz(uint32_t code) {'); b=src.index('uint32_t XE::wrapTGLDPPower(void *port, uint8_t state) {')
open(sys.argv[2],'w').write(src[a:b])
