#ifndef VICE_METAL_RENDERER_H
#define VICE_METAL_RENDERER_H

#ifdef __OBJC__
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdint.h>

typedef struct {
    const unsigned char *pixels;
    unsigned int width, height;
    float scaleX, scaleY;
    int flipX, flipY, rotate;
    float background;
    uint64_t sequence;
    uint64_t presentID;
    double completed, planned, target;
    double nominal;
    unsigned int queued, dropped;
    char kind;
} ViceMetalFrame;

@interface ViceMetalSubmission : NSObject {
@public
    id<MTLCommandBuffer> command;
    NSCondition *condition;
    BOOL gpuDone;
    BOOL gpuSucceeded;
    double gpuTime, submitted, presented, returned, started;
    BOOL presentationDone, unavailable;
    ViceMetalFrame frame;
}
@property(readonly) BOOL commandSucceeded;
- (void)wait;
- (double)presentedTime;
@end

@interface ViceMetalRenderer : NSObject {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> rgbaPipeline, bgraPipeline;
    ViceMetalSubmission *inflight;
    unsigned int unavailable;
}
@property(readonly) unsigned int unavailable;
- (id)initWithDevice:(id<MTLDevice>)device shaderPath:(NSString *)path error:(NSError **)error;
- (id<MTLTexture>)offscreenWidth:(unsigned int)width height:(unsigned int)height;
- (ViceMetalSubmission *)drawFrame:(ViceMetalFrame)frame texture:(id<MTLTexture>)texture
    drawable:(id<CAMetalDrawable>)drawable target:(double)target;
- (ViceMetalSubmission *)presentFrame:(ViceMetalFrame)frame layer:(CAMetalLayer *)layer target:(double)target;
@end
#endif

#ifndef VICE_METAL_TEST
#include "videoarch.h"
extern vice_renderer_backend_t vice_metal_backend;
unsigned int vice_metal_frame_width(video_canvas_t *canvas);
#endif
#endif
