#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>
#include <math.h>

static NSString *const shader =
    @"#include <metal_stdlib>\nusing namespace metal;\n"
     "vertex float4 v(uint i [[vertex_id]], constant float &t [[buffer(0)]]) {"
     "float2 p[] = {float2(-.16,-.18),float2(.16,-.18),float2(0,.18)};"
     "return float4(p[i]+float2(.65*sin(t),0),0,1); }"
     "fragment float4 f() { return float4(.24,.61,.72,1); }";

int runPanelTest(void) {
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [app finishLaunching];
    NSScreen *panel = nil;
    CGDirectDisplayID display = 0;
    for (NSScreen *screen in NSScreen.screens) {
        display = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        if (CGDisplayIsBuiltin(display)) { panel = screen; break; }
    }
    if (!panel) { puts("The internal display is unavailable."); return 1; }
    id<MTLDevice> gpu = CGDirectDisplayCopyCurrentMetalDevice(display);
    if (!gpu) { puts("The internal display has no current Metal device."); return 1; }
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
    if (!mode) { puts("Cannot read the active panel mode."); return 1; }
    double hz = CGDisplayModeGetRefreshRate(mode);
    printf("Display-attached Metal device: %s\nActive mode: %zu x %zu pixels\n",
           gpu.name.UTF8String, CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode));
    if (hz > 0) printf("Mode refresh: %.2f Hz\n", hz);
    else puts("macOS did not publish a fixed refresh rate for this mode.");
    CGDisplayModeRelease(mode);

    NSError *error = nil;
    id<MTLLibrary> library = [gpu newLibraryWithSource:shader options:nil error:&error];
    if (!library) { fprintf(stderr, "Metal compilation failed: %s\n", error.localizedDescription.UTF8String); return 1; }
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [library newFunctionWithName:@"v"];
    desc.fragmentFunction = [library newFunctionWithName:@"f"];
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> pipeline = [gpu newRenderPipelineStateWithDescriptor:desc error:&error];
    id<MTLCommandQueue> queue = [gpu newCommandQueue];
    if (!pipeline || !queue) { puts("Metal rendering pipeline unavailable."); return 1; }

    NSWindow *window = [[NSWindow alloc] initWithContentRect:panel.frame styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    window.level = NSStatusWindowLevel + 1;
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = gpu;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.displaySyncEnabled = YES;
    layer.frame = window.contentView.bounds;
    layer.contentsScale = panel.backingScaleFactor;
    layer.drawableSize = [window.contentView convertRectToBacking:window.contentView.bounds].size;
    window.contentView.layer = layer;
    window.contentView.wantsLayer = YES;
    [window orderFrontRegardless];
    [CATransaction flush];

    NSMutableArray<NSNumber *> *times = [NSMutableArray array];
    CFTimeInterval start = CACurrentMediaTime();
    id<MTLCommandBuffer> last = nil;
    while (CACurrentMediaTime() - start < 9) {
        @autoreleasepool {
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.0002]];
            id<CAMetalDrawable> frame = [layer nextDrawable];
            if (!frame) continue;
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = frame.texture;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(.04,.08,.10,1);
            last = [queue commandBuffer];
            id<MTLRenderCommandEncoder> enc = [last renderCommandEncoderWithDescriptor:pass];
            float elapsed = (float)(CACurrentMediaTime() - start);
            [enc setRenderPipelineState:pipeline];
            [enc setVertexBytes:&elapsed length:sizeof(elapsed) atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [enc endEncoding];
            [frame addPresentedHandler:^(id<MTLDrawable> presented) {
                CFTimeInterval t = presented.presentedTime;
                if (t >= start+1) { @synchronized(times) { [times addObject:@(t)]; } }
            }];
            [last presentDrawable:frame];
            [last commit];
        }
    }
    [last waitUntilCompleted];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.15]];
    [window orderOut:nil];
    if (!last || last.status == MTLCommandBufferStatusError) { puts("GPU rendering failed."); return 1; }
    NSArray<NSNumber *> *samples;
    @synchronized(times) { samples = [times sortedArrayUsingSelector:@selector(compare:)]; }
    double span = samples.lastObject.doubleValue - samples.firstObject.doubleValue;
    if (span < 4 || samples.count < 2) { puts("Insufficient on-screen presentation timestamps."); return 1; }
    NSUInteger slow = 0;
    for (NSUInteger i=1; i<samples.count; ++i)
        if (samples[i].doubleValue - samples[i-1].doubleValue > .025) ++slow;
    printf("Moving triangle on the internal panel: %.2f presented FPS across %.2f seconds.\n"
           "%lu of %lu frame intervals exceeded 25 ms.\n", (samples.count-1)/span, span,
           (unsigned long)slow, (unsigned long)(samples.count-1));
    return 0;
}
