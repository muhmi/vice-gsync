#import "metal_renderer.h"
#ifndef VICE_METAL_TEST
#include "opengl_renderer.h"
#endif
#import <Cocoa/Cocoa.h>

static double metal_now(void)
{
    struct timespec time;
    clock_gettime(CLOCK_UPTIME_RAW, &time);
    return time.tv_sec * 1000.0 + time.tv_nsec / 1000000.0;
}

@implementation ViceMetalSubmission
- (id)init
{
    self = [super init];
    if (self) condition = [[NSCondition alloc] init];
    return self;
}
- (void)wait
{
    [condition lock];
    while (!gpuDone) [condition wait];
    [condition unlock];
}
- (BOOL)commandSucceeded
{
    [self wait];
    return gpuSucceeded;
}
- (double)presentedTime
{
    [condition lock];
    double result = presented;
    [condition unlock];
    return result;
}
- (void)dealloc
{
    [command release];
    [condition release];
    [super dealloc];
}
@end

@implementation ViceMetalRenderer
@synthesize unavailable;
- (id)initWithDevice:(id<MTLDevice>)givenDevice shaderPath:(NSString *)path error:(NSError **)error
{
    self = [super init];
    if (!self) return nil;
    if (@available(macOS 10.15.4, *)) {
    } else {
        if (error) *error = [NSError errorWithDomain:@"VICE Metal" code:3
            userInfo:@{NSLocalizedDescriptionKey: @"Metal presentation timestamps require macOS 10.15.4 or newer"}];
        [self release];
        return nil;
    }
#ifdef VICE_RENDERER_TEST
    const char *failure = getenv("VICE_METAL_INIT_FAILURE");
    if (failure && strcmp(failure, "device") == 0) givenDevice = nil;
#endif
    device = [givenDevice retain];
#ifdef VICE_RENDERER_TEST
    if (!failure || strcmp(failure, "queue") != 0)
#endif
    queue = [device newCommandQueue];
    if (!device || !queue) {
        if (error) *error = [NSError errorWithDomain:@"VICE Metal" code:1
            userInfo:@{NSLocalizedDescriptionKey: device ? @"Metal command queue unavailable" : @"Metal device unavailable"}];
        [self release];
        return nil;
    }
    NSString *source = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:error];
#ifdef VICE_RENDERER_TEST
    if (failure && strcmp(failure, "shader") == 0) source = @"invalid Metal shader";
#endif
    id<MTLLibrary> library = source ? [device newLibraryWithSource:source options:nil error:error] : nil;
    id<MTLFunction> vertex = [library newFunctionWithName:@"vice_vertex"];
    id<MTLFunction> fragment = [library newFunctionWithName:@"vice_nearest"];
    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = vertex;
    descriptor.fragmentFunction = fragment;
    BOOL buildPipeline = vertex && fragment;
#ifdef VICE_RENDERER_TEST
    if (failure && strcmp(failure, "pipeline") == 0) buildPipeline = NO;
#endif
    if (buildPipeline) {
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        rgbaPipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:error];
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        bgraPipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:error];
    }
    [descriptor release];
    [vertex release];
    [fragment release];
    [library release];
    if (!rgbaPipeline || !bgraPipeline) {
        if (error && !*error) *error = [NSError errorWithDomain:@"VICE Metal" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"Bundled Metal shader functions or pipelines are unavailable"}];
        [self release];
        return nil;
    }
    return self;
}
- (id<MTLTexture>)offscreenWidth:(unsigned int)width height:(unsigned int)height
{
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
        MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    return [[device newTextureWithDescriptor:descriptor] autorelease];
}
- (ViceMetalSubmission *)drawFrame:(ViceMetalFrame)frame texture:(id<MTLTexture>)output
    drawable:(id<CAMetalDrawable>)drawable target:(double)target
{
    [inflight wait];
    [inflight release];
    inflight = nil;
    double started = metal_now();
    id<MTLTexture> upload = [self offscreenWidth:frame.width height:frame.height];
    [upload replaceRegion:MTLRegionMake2D(0, 0, frame.width, frame.height) mipmapLevel:0
        withBytes:frame.pixels bytesPerRow:frame.width * 4];
    ViceMetalSubmission *submission = [[[ViceMetalSubmission alloc] init] autorelease];
    submission->frame = frame;
    submission->frame.pixels = NULL;
    submission->started = started;
    submission->command = [[queue commandBuffer] retain];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = output;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(frame.background, frame.background, frame.background, 1);
    float vertices[4][4] = {{-1, 1, 0, 0}, {1, 1, 1, 0}, {-1, -1, 0, 1}, {1, -1, 1, 1}};
    for (int i = 0; i < 4; i++) {
        if (frame.flipX) vertices[i][2] = 1 - vertices[i][2];
        if (frame.flipY) vertices[i][3] = 1 - vertices[i][3];
        float x = vertices[i][0] * frame.scaleX;
        float y = vertices[i][1] * frame.scaleY;
        vertices[i][0] = frame.rotate ? y : x;
        vertices[i][1] = frame.rotate ? -x : y;
    }
    id<MTLRenderCommandEncoder> encoder = [submission->command renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:output.pixelFormat == MTLPixelFormatRGBA8Unorm ? rgbaPipeline : bgraPipeline];
    [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
    [encoder setFragmentTexture:upload atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    [submission->command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        [submission->condition lock];
        submission->gpuTime = metal_now();
        submission->gpuSucceeded = completed.status == MTLCommandBufferStatusCompleted;
        submission->gpuDone = YES;
        [submission->condition broadcast];
        [submission->condition unlock];
    }];
    submission->submitted = metal_now();
    if (drawable) {
        [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
            [submission->condition lock];
            submission->presented = shown.presentedTime * 1000.0;
            submission->presentationDone = YES;
            [submission->condition broadcast];
            [submission->condition unlock];
        }];
        if (target > 0) [submission->command presentDrawable:drawable atTime:target / 1000.0];
        else [submission->command presentDrawable:drawable];
    }
    [submission->command commit];
    submission->returned = metal_now();
    inflight = [submission retain];
    return submission;
}
- (ViceMetalSubmission *)presentFrame:(ViceMetalFrame)frame layer:(CAMetalLayer *)layer target:(double)target
{
    [inflight wait];
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) {
        unavailable++;
        return nil;
    }
    return [self drawFrame:frame texture:drawable.texture drawable:drawable target:target];
}
- (void)dealloc
{
    [inflight wait];
    [inflight release];
    [rgbaPipeline release];
    [bgraPipeline release];
    [queue release];
    [device release];
    [super dealloc];
}
@end

#ifndef VICE_METAL_TEST
#include <gdk/gdkquartz.h>
#include "lib.h"
#include "log.h"
#include "machine.h"
#include "monitor.h"
#include "palette.h"
#include "render_queue.h"
#include "render_thread.h"
#include "opengl_pacing.h"
#include "sysfile.h"
#include "ui.h"
#include "uistatusbar.h"
#include "vsync.h"
#include "vsyncapi.h"

NSView *gdk_quartz_window_get_nsview(GdkWindow *window);

typedef struct {
    video_canvas_t *canvas;
    ViceMetalRenderer *renderer;
    NSView *view;
    CAMetalLayer *layer;
    render_thread_t thread;
    void *queue;
    opengl_pacing_t pacing;
    ViceMetalSubmission *feedback;
    NSMutableArray *pending;
    FILE *stats;
    unsigned int width, height, dropped;
    unsigned int emulated_width, emulated_height;
    unsigned int frame_width;
    uint64_t present_id;
    float aspect;
    float background;
    BOOL stopping, redraw;
    backbuffer_t *last;
} metal_context;

static void metal_flush_stats(metal_context *context, BOOL final)
{
    double deadline = metal_now() + (final ? 500 : 0);
    do {
        while (context->pending.count) {
            ViceMetalSubmission *record = [context->pending objectAtIndex:0];
            [record->condition lock];
            BOOL resolved = record->gpuDone && record->presentationDone;
            BOOL gpuFailed = record->gpuDone && !record->gpuSucceeded && !record->unavailable;
            double presented = record->presented;
            double gpu = record->gpuTime;
            [record->condition unlock];
            if (!resolved && (final ? metal_now() < deadline : metal_now() < record->submitted + 500)) break;
            ViceMetalFrame f = record->frame;
            fprintf(context->stats, "%c,%.6f,%.6f,%.6f,%.6f,%u,%u,%.6f,%llu,%.6f,%.6f,%s,%llu\n",
                f.kind, f.completed, f.target, record->submitted, record->returned,
                f.queued, f.dropped, 1000 / f.nominal, (unsigned long long)f.sequence,
                gpu, presented, gpuFailed ? "gpu_error" : record->unavailable ? "unavailable" :
                    resolved ? (presented > 0 ? "presented" : "unpresented") : "unresolved",
                (unsigned long long)f.presentID);
            [context->pending removeObjectAtIndex:0];
        }
        if (!final || !context->pending.count) break;
        [NSThread sleepForTimeInterval:0.001];
    } while (YES);
    if (context->stats) fflush(context->stats);
}

static void metal_worker(void *job_data, void *pool_data)
{
    metal_context *context = pool_data;
    video_canvas_t *canvas = context->canvas;
    render_job_t job = (render_job_t)vice_ptr_to_int(job_data);
    @autoreleasepool {
        if (job == render_thread_init) {
            archdep_thread_init();
            return;
        }
        if (context->feedback) {
            ViceMetalSubmission *previous = context->feedback;
            [previous wait];
            if (previous->frame.planned > 0) {
                opengl_pacing_ready(&context->pacing, previous->frame.planned,
                    previous->frame.completed, previous->gpuTime - previous->started);
            }
            [previous release];
            context->feedback = nil;
        }
        metal_flush_stats(context, job == render_thread_shutdown);
        if (job == render_thread_shutdown) {
            archdep_thread_shutdown();
            return;
        }
        pthread_mutex_lock(&canvas->lock);
        if (context->stopping) {
            pthread_mutex_unlock(&canvas->lock);
            return;
        }
        backbuffer_t *buffer = render_queue_dequeue_for_display(context->queue);
        BOOL is_new = buffer != NULL;
        if (buffer) {
            if (context->last) render_queue_return_to_pool(context->queue, context->last);
            context->last = buffer;
        } else {
            context->redraw = NO;
            buffer = context->last;
        }
        if (!buffer || !context->layer || context->width == 0 || context->height == 0) {
            pthread_mutex_unlock(&canvas->lock);
            return;
        }
        ViceMetalFrame frame = {.pixels = buffer->pixel_data, .width = buffer->width,
            .height = buffer->height, .scaleX = 1, .scaleY = 1,
            .flipX = canvas->videoconfig->flipx, .flipY = canvas->videoconfig->flipy,
            .rotate = canvas->videoconfig->rotate, .sequence = buffer->sequence,
            .presentID = ++context->present_id,
            .background = context->background,
            .completed = buffer->completed_time_ms, .kind = is_new ? 'N' : 'D',
            .queued = render_queue_length(context->queue), .dropped = context->dropped};
        context->frame_width = buffer->width;
        double refresh = vsync_get_refresh_frequency();
        frame.nominal = refresh > 1 ? 1000 / refresh : 20;
        BOOL paced = canvas->videoconfig->vsync && !vsync_get_warp_mode();
        float vw = context->width, vh = context->height;
        if (canvas->videoconfig->aspect_mode != VIDEO_ASPECT_MODE_NONE && vw > 0 && vh > 0) {
            float viewport = frame.rotate ? vh / vw : vw / vh;
            float aspect = (float)buffer->width / buffer->height;
            aspect *= canvas->videoconfig->aspect_mode == VIDEO_ASPECT_MODE_TRUE ?
                buffer->pixel_aspect_ratio : canvas->videoconfig->aspect_ratio;
            if (aspect < viewport) frame.scaleX = aspect / viewport;
            else frame.scaleY = viewport / aspect;
        }
        canvas->screen_display_w = vw * (frame.rotate ? frame.scaleY : frame.scaleX);
        canvas->screen_display_h = vh * (frame.rotate ? frame.scaleX : frame.scaleY);
        canvas->screen_origin_x = (vw - canvas->screen_display_w) / 2;
        canvas->screen_origin_y = (vh - canvas->screen_display_h) / 2;
        CAMetalLayer *layer = [context->layer retain];
        pthread_mutex_unlock(&canvas->lock);
        if (is_new && paced) {
            frame.target = opengl_pacing_schedule(&context->pacing, frame.completed,
                frame.queued, metal_now(), frame.nominal, RENDER_QUEUE_MAX_BACKBUFFERS);
            frame.planned = context->pacing.planned_ms;
        } else {
            opengl_pacing_stop(&context->pacing);
        }
        ViceMetalSubmission *record = [context->renderer presentFrame:frame layer:layer target:frame.target];
        context->feedback = [record retain];
        if (!record && context->stats) {
            record = [[[ViceMetalSubmission alloc] init] autorelease];
            record->frame = frame;
            record->frame.pixels = NULL;
            record->submitted = record->returned = metal_now();
            record->gpuDone = record->presentationDone = record->unavailable = YES;
        }
        if (record && context->stats) [context->pending addObject:record];
        [layer release];
    }
}

static void metal_layout(GtkWidget *widget, GtkAllocation *allocation, gpointer data)
{
    video_canvas_t *canvas = data;
    metal_context *context = canvas->renderer_context;
    GtkAllocation area;
    gtk_widget_get_allocation(canvas->event_box, &area);
    GdkWindow *window = gtk_widget_get_window(canvas->event_box);
    if (!window || !context->view) return;
    NSView *parent = gdk_quartz_window_get_nsview(window);
    if (!parent || !context->view) return;
    NSRect rect = NSMakeRect(area.x, area.y, area.width, area.height);
    if (!parent.isFlipped) rect.origin.y = parent.frame.size.height - area.y - area.height;
    [context->view setFrame:rect];
    NSSize backing = [context->view convertSizeToBacking:rect.size];
    pthread_mutex_lock(&canvas->lock);
    context->width = area.width;
    context->height = area.height;
    context->background = ui_is_fullscreen_from_canvas(canvas) ? 0 : 0.5f;
    context->layer.contentsScale = context->view.window.backingScaleFactor;
    context->layer.drawableSize = backing;
    pthread_mutex_unlock(&canvas->lock);
}

static void metal_realize(GtkWidget *widget, gpointer data)
{
    video_canvas_t *canvas = data;
    metal_context *context = canvas->renderer_context;
    NSView *parent = gdk_quartz_window_get_nsview(gtk_widget_get_window(widget));
    context->view = [[NSView alloc] initWithFrame:NSZeroRect];
    context->layer = [[CAMetalLayer alloc] init];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    context->layer.device = device;
    [device release];
    context->layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    context->layer.framebufferOnly = YES;
    context->layer.maximumDrawableCount = 2;
    CGColorSpaceRef colorspace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    context->layer.colorspace = colorspace;
    CGColorSpaceRelease(colorspace);
    context->view.wantsLayer = YES;
    context->view.layer = context->layer;
    [parent addSubview:context->view];
    metal_layout(widget, NULL, canvas);
    context->thread = render_thread_create(metal_worker, context);
    g_signal_connect_unlocked(gtk_widget_get_toplevel(widget), "size-allocate", G_CALLBACK(metal_layout), canvas);
}

static void metal_unrealize(GtkWidget *widget, gpointer data)
{
    video_canvas_t *canvas = data;
    metal_context *context = canvas->renderer_context;
    g_signal_handlers_disconnect_by_func(gtk_widget_get_toplevel(widget), G_CALLBACK(metal_layout), canvas);
    pthread_mutex_lock(&canvas->lock);
    context->stopping = YES;
    pthread_mutex_unlock(&canvas->lock);
    if (context->thread) {
        render_thread_initiate_shutdown(context->thread);
        render_thread_join(context->thread);
        context->thread = NULL;
    }
    [context->view removeFromSuperview];
    [context->view release];
    context->view = nil;
    [context->layer release];
    context->layer = nil;
}

static void metal_initialise(video_canvas_t *canvas)
{
    metal_context *context = lib_calloc(1, sizeof(*context));
    char *path = NULL;
    FILE *shader = sysfile_open("nearest.metal", "Metal", &path, "rb");
    if (shader) fclose(shader);
    NSError *error = nil;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    context->renderer = [[ViceMetalRenderer alloc] initWithDevice:device
        shaderPath:path ? @(path) : @"" error:&error];
    [device release];
    lib_free(path);
    if (!context->renderer) {
        NSString *reason = [[error.localizedDescription componentsSeparatedByCharactersInSet:
            NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
        log_message(LOG_DEFAULT, "Metal initialization failed: %s; using OpenGL",
            reason.UTF8String);
        lib_free(context);
        canvas->renderer_backend = &vice_opengl_backend;
        vice_opengl_backend.initialise(canvas);
        return;
    }
    context->canvas = canvas;
    context->queue = render_queue_create();
    context->pending = [[NSMutableArray alloc] init];
    opengl_pacing_init(&context->pacing);
    const char *stats = getenv("VICE_PRESENT_STATS");
    if (stats && *stats) {
        char *filename = g_strdup_printf("%s.canvas%d.csv", stats, canvas->window_index);
        context->stats = fopen(filename, "w");
        if (context->stats) fprintf(context->stats,
            "kind,completed_ms,target_ms,ready_ms,done_ms,queued,dropped,emulated_hz,frame_id,gpu_ms,presented_ms,status,present_id\n");
        else log_error(LOG_DEFAULT, "Metal: cannot write present stats to %s", filename);
        g_free(filename);
    }
    canvas->renderer_context = context;
    g_signal_connect(canvas->event_box, "realize", G_CALLBACK(metal_realize), canvas);
    g_signal_connect(canvas->event_box, "unrealize", G_CALLBACK(metal_unrealize), canvas);
    g_signal_connect_unlocked(canvas->event_box, "size-allocate", G_CALLBACK(metal_layout), canvas);
}

static void metal_update(video_canvas_t *canvas, unsigned int width, unsigned int height)
{
    pthread_mutex_lock(&canvas->lock);
    metal_context *context = canvas->renderer_context;
    context->frame_width = width;
    context->emulated_width = width;
    context->emulated_height = height;
    context->aspect = canvas->geometry->pixel_aspect_ratio;
    pthread_mutex_unlock(&canvas->lock);
}

static void metal_refresh(video_canvas_t *canvas, unsigned int xs, unsigned int ys,
    unsigned int xi, unsigned int yi, unsigned int width, unsigned int height)
{
    pthread_mutex_lock(&canvas->lock);
    metal_context *context = canvas->renderer_context;
    if (!context || context->stopping || !context->thread) {
        pthread_mutex_unlock(&canvas->lock);
        return;
    }
    unsigned int w = context->emulated_width;
    unsigned int h = context->emulated_height;
    backbuffer_t *buffer = render_queue_get_from_pool(context->queue, w * h * 4);
    if (!buffer) {
        context->dropped++;
        pthread_mutex_unlock(&canvas->lock);
        return;
    }
    buffer->width = w;
    buffer->height = h;
    buffer->pixel_aspect_ratio = context->aspect;
    video_canvas_render(canvas, buffer->pixel_data, width, height, xs, ys, xi, yi, w * 4);
    buffer->completed_time_ms = metal_now();
    render_queue_enqueue_for_display(context->queue, buffer);
    render_thread_push_job(context->thread, render_thread_render);
    pthread_mutex_unlock(&canvas->lock);
}

static void metal_redraw(GdkFrameClock *clock, video_canvas_t *canvas)
{
    ui_update_statusbars();
    pthread_mutex_lock(&canvas->lock);
    metal_context *context = canvas->renderer_context;
    if (context && context->layer) context->layer.displaySyncEnabled = canvas->videoconfig->vsync && !vsync_get_warp_mode();
    if (context && context->thread && !context->stopping && !context->redraw &&
        (ui_pause_active() || monitor_is_inside_monitor() || machine_is_jammed())) {
        context->redraw = YES;
        render_thread_push_job(context->thread, render_thread_render);
    }
    pthread_mutex_unlock(&canvas->lock);
}

static void metal_destroy(video_canvas_t *canvas)
{
    metal_context *context = canvas->renderer_context;
    if (context->view) metal_unrealize(canvas->event_box, canvas);
    g_signal_handlers_disconnect_by_func(canvas->event_box, G_CALLBACK(metal_realize), canvas);
    g_signal_handlers_disconnect_by_func(canvas->event_box, G_CALLBACK(metal_unrealize), canvas);
    g_signal_handlers_disconnect_by_func(canvas->event_box, G_CALLBACK(metal_layout), canvas);
    if (context->last) render_queue_return_to_pool(context->queue, context->last);
    render_queue_destroy(context->queue);
    [context->renderer release];
    [context->pending release];
    if (context->stats) fclose(context->stats);
    lib_free(context);
    canvas->renderer_context = NULL;
}

static void metal_palette(video_canvas_t *canvas)
{
    if (!canvas->palette) return;
    video_render_color_tables_t *tables = &canvas->videoconfig->color_tables;
    for (unsigned int i = 0; i < canvas->palette->num_entries; i++) {
        palette_entry_t color = canvas->palette->entries[i];
        uint32_t rgba = color.red | (color.green << 8) | (color.blue << 16) | (0xffU << 24);
        video_render_setphysicalcolor(canvas->videoconfig, i, rgba, 32);
    }
    for (int i = 0; i < 256; i++) video_render_setrawrgb(tables, i, i, i << 8, i << 16);
    video_render_setrawalpha(tables, 0xffU << 24);
    video_render_initraw(canvas->videoconfig);
}

unsigned int vice_metal_frame_width(video_canvas_t *canvas)
{
    metal_context *context = canvas->renderer_context;
    return context->frame_width;
}

vice_renderer_backend_t vice_metal_backend = {
    metal_initialise, metal_update, metal_destroy, metal_refresh, metal_redraw, metal_palette
};
#endif
