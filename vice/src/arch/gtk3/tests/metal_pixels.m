#import "metal_renderer.h"
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CATransaction.h>
#include <mach/mach_time.h>
#include <assert.h>
#include <string.h>

static void stop_test_app(void)
{
    [NSApp stop:nil];
    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
        location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0
        context:nil subtype:0 data1:0 data2:0] atStart:NO];
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        assert(argc == 2 || argc == 3);
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        for (int i = 0; i < 2; i++) {
            double before = mach_absolute_time() * (double)timebase.numer / timebase.denom / 1e6;
            struct timespec now;
            clock_gettime(CLOCK_UPTIME_RAW, &now);
            double raw = now.tv_sec * 1000.0 + now.tv_nsec / 1e6;
            double after = mach_absolute_time() * (double)timebase.numer / timebase.denom / 1e6;
            assert(raw >= before - 0.001 && raw <= after + 0.001);
            [NSThread sleepForTimeInterval:0.02];
        }
        NSError *error = nil;
        ViceMetalRenderer *missing = [[ViceMetalRenderer alloc] initWithDevice:nil
            shaderPath:@(argv[1]) error:&error];
        assert(missing == nil && error != nil);

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        __block ViceMetalRenderer *renderer = [[ViceMetalRenderer alloc]
            initWithDevice:device shaderPath:@(argv[1]) error:&error];
        if (!renderer) {
            NSLog(@"Metal initialization failed: %@", error);
            return 1;
        }
        const unsigned char pixels[] = {
            255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 64,
            11, 22, 33, 0, 44, 55, 66, 200, 77, 88, 99, 255
        };
        unsigned char actual[sizeof(pixels)];
        unsigned char reusable[sizeof(pixels)];
        memcpy(reusable, pixels, sizeof(pixels));
        id<MTLTexture> output = [renderer offscreenWidth:3 height:2];
        ViceMetalFrame frame = { .pixels = reusable, .width = 3, .height = 2,
            .scaleX = 1, .scaleY = 1, .sequence = 42 };
        ViceMetalSubmission *submission = [renderer drawFrame:frame texture:output
            drawable:nil target:0];
        memset(reusable, 0xa5, sizeof(reusable));
        [submission wait];
        assert(submission.commandSucceeded);
        [output getBytes:actual bytesPerRow:12 fromRegion:MTLRegionMake2D(0, 0, 3, 2)
            mipmapLevel:0];
        assert(memcmp(actual, pixels, sizeof(pixels)) == 0);
        frame.pixels = pixels;
        MTLTextureDescriptor *bgra = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            MTLPixelFormatBGRA8Unorm width:3 height:2 mipmapped:NO];
        bgra.storageMode = MTLStorageModeShared;
        bgra.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> drawableFormat = [device newTextureWithDescriptor:bgra];
        [[renderer drawFrame:frame texture:drawableFormat drawable:nil target:0] wait];
        [drawableFormat getBytes:actual bytesPerRow:12 fromRegion:MTLRegionMake2D(0, 0, 3, 2) mipmapLevel:0];
        for (unsigned int i = 0; i < sizeof(pixels); i += 4) {
            assert(actual[i] == pixels[i + 2] && actual[i + 1] == pixels[i + 1] &&
                actual[i + 2] == pixels[i] && actual[i + 3] == pixels[i + 3]);
        }
        [drawableFormat release];
        for (int rotate = 0; rotate <= 1; rotate++) {
            for (int flip = 0; flip < 4; flip++) {
                unsigned int ow = rotate ? 4 : 6, oh = rotate ? 6 : 4;
                id<MTLTexture> scaled = [renderer offscreenWidth:ow height:oh];
                frame.rotate = rotate;
                frame.flipX = flip & 1;
                frame.flipY = flip & 2;
                [[renderer drawFrame:frame texture:scaled drawable:nil target:0] wait];
                unsigned char result[6 * 4 * 4];
                [scaled getBytes:result bytesPerRow:ow * 4 fromRegion:MTLRegionMake2D(0, 0, ow, oh)
                    mipmapLevel:0];
                for (unsigned int y = 0; y < oh; y++) {
                    for (unsigned int x = 0; x < ow; x++) {
                        unsigned int sx = rotate ? y / 2 : x / 2;
                        unsigned int sy = rotate ? 1 - x / 2 : y / 2;
                        if (frame.flipX) sx = 2 - sx;
                        if (frame.flipY) sy = 1 - sy;
                        assert(memcmp(result + (y * ow + x) * 4, pixels + (sy * 3 + sx) * 4, 4) == 0);
                    }
                }
            }
        }
        frame.rotate = frame.flipX = frame.flipY = 0;
        assert([renderer presentFrame:frame layer:nil target:0] == nil);
        assert(renderer.unavailable == 1);
        if (argc == 3) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            [NSApp finishLaunching];
            for (NSScreen *screen in NSScreen.screens) {
                CGDirectDisplayID display = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
                CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
                NSLog(@"Display %@ frame=%@ built-in=%d mode-hz=%.3f maximum-hz=%ld", screen.localizedName,
                    NSStringFromRect(screen.frame), CGDisplayIsBuiltin(display),
                    CGDisplayModeGetRefreshRate(mode), (long)screen.maximumFramesPerSecond);
                CGDisplayModeRelease(mode);
            }
            NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 300, 200)
                styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
            CAMetalLayer *layer = [CAMetalLayer layer];
            layer.device = device;
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            layer.frame = window.contentView.bounds;
            layer.drawableSize = CGSizeMake(300, 200);
            window.contentView.wantsLayer = YES;
            window.contentView.layer = layer;
            [window makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
            [CATransaction flush];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            __block ViceMetalSubmission *shown = nil;
            __block BOOL destroyed = NO;
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
            [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
                if (deadline.timeIntervalSinceNow <= 0) {
                    [timer invalidate];
                    stop_test_app();
                    return;
                }
                if (!shown) {
                    shown = [[renderer presentFrame:frame layer:layer target:0] retain];
                    return;
                }
                if (shown.presentedTime > 0) {
                    if (!destroyed) {
                        [shown release];
                        struct timespec now;
                        clock_gettime(CLOCK_UPTIME_RAW, &now);
                        double future = now.tv_sec * 1000.0 + now.tv_nsec / 1e6 + 200;
                        shown = [[renderer presentFrame:frame layer:layer target:future] retain];
                        [renderer release];
                        assert(shown.presentedTime == 0);
                        destroyed = YES;
                        return;
                    }
                } else {
                    [shown->condition lock];
                    BOOL rejected = shown->presentationDone;
                    [shown->condition unlock];
                    if (!destroyed && rejected) {
                        [shown release];
                        shown = nil;
                    }
                    return;
                }
                if (destroyed) {
                    [timer invalidate];
                    stop_test_app();
                }
            }];
            [NSApp run];
            if (shown.presentedTime <= 0) {
                NSLog(@"Presentation missing: screen=%@ visible=%d occlusion=%lu GPU=%d layer=%@",
                    window.screen, window.visible, (unsigned long)window.occlusionState,
                    shown.commandSucceeded, layer);
            }
            assert(shown.presentedTime > 0 && shown->frame.sequence == 42);
            printf("Metal visible: frame %llu presented_ms %.6f after renderer destruction\n",
                (unsigned long long)shown->frame.sequence, shown.presentedTime);
            [shown release];
            if (destroyed) renderer = nil;
            [window orderOut:nil];
            [window release];
        }
        [renderer release];
        [device release];
        puts("Metal: exact RGBA pixels, device unavailable, nil drawable passed");
    }
    return 0;
}
