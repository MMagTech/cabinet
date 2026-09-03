// Temporary instrumentation for the PS2 black-screen bug. Reads the
// final CAMetalDrawable after the GPU has finished with it, which is
// the one thing no earlier signal could see: GSQueueSnapshot reads the
// GS render target, the frame counter reads the CPU, and the present
// trace stops at "presentDrawable succeeded".
//
// Off unless CABINET_DRAWABLE_PROBE is set in the environment. Its
// value is the directory the frame dumps and the probe log go to, or
// "1" for ~/Documents/Cabinet/PS2/logs. CABINET_LAYER_FBONLY=0 turns
// the layer's framebufferOnly off, which is what makes the drawable
// readable at all.
//
// Compiled into PCSX2 by tools/patch-pcsx2-mac.py, which also places
// the three calls below. Remove the file, the patch section and the
// calls together when the bug is closed.

#pragma once

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

/// Main thread, once the layer is attached. Applies the framebufferOnly
/// toggle and logs every layer, view and device property that could
/// differ from the AppKit build.
void CabinetProbeConfigureLayer(CAMetalLayer* layer, UIView* view);

/// GS thread, from EndPresent after the present pass is encoded and
/// before the command buffer is committed. Encodes a copy of the
/// drawable into a shared texture and registers completion and
/// presented handlers.
void CabinetProbePresent(id<MTLCommandBuffer> buf, id<CAMetalDrawable> drawable, CAMetalLayer* layer, id<MTLDevice> dev);

/// GS thread, from FlushEncoders before the draw command buffer is
/// committed. Reports any command buffer that does not complete
/// cleanly, present or not.
void CabinetProbeCommandBuffer(id<MTLCommandBuffer> buf);
