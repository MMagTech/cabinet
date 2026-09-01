// Cabinet's Mac Catalyst replacement for PCSX2's common/CocoaTools.mm.
//
// The original is AppKit: it makes its own NSWindow, attaches a
// CAMetalLayer to an NSView, reads the refresh rate off NSScreen and
// runs its own Cocoa event loop. None of that exists on Catalyst, and
// none of it should: Cabinet owns the window, the run loop and the
// menus, exactly as it does for every other core.
//
// So this file answers the same header, CocoaTools.h, with the UIKit
// equivalents, and turns the parts that were only ever there for
// PCSX2's own desktop frontend into honest no-ops. It is compiled in
// place of common/CocoaTools.mm; see tools/patch-pcsx2-mac.py.
//
// THE VIEW CONTRACT: window_handle is a UIView whose +layerClass is
// CAMetalLayer. UIView's layer is read-only, so unlike AppKit we
// cannot hand the view a layer after the fact, and the renderer must
// not be given a plain view with a sublayer bolted on: PCSX2 resizes
// and presents through the layer it is handed, and a sublayer would
// silently stop tracking the view's bounds.

#if !__has_feature(objc_arc)
	#error "Compile this with -fobjc-arc"
#endif

#include "common/CocoaTools.h"
#include "common/Console.h"
#include "common/HostSys.h"
#include "common/WindowInfo.h"

#include <UIKit/UIKit.h>
#include <QuartzCore/QuartzCore.h>

static NSString* _Nonnull NSStringFromStringView(std::string_view sv)
{
	return [[NSString alloc] initWithBytes:sv.data() length:sv.size() encoding:NSUTF8StringEncoding];
}

// MARK: - Metal layers

bool CocoaTools::CreateMetalLayer(WindowInfo* wi)
{
	if (![NSThread isMainThread])
	{
		bool ret = false;
		dispatch_sync(dispatch_get_main_queue(), [&ret, wi] { ret = CreateMetalLayer(wi); });
		return ret;
	}

	UIView* view = (__bridge UIView*)wi->window_handle;
	if (!view)
	{
		Console.Error("No view to create a Metal layer on.");
		return false;
	}

	CAMetalLayer* layer = (CAMetalLayer*)[view layer];
	if (![layer isKindOfClass:[CAMetalLayer class]])
	{
		Console.Error("View is not backed by a CAMetalLayer.");
		return false;
	}

	[layer setContentsScale:[[view traitCollection] displayScale]];
	wi->surface_handle = (__bridge_retained void*)layer;
	return true;
}

void CocoaTools::DestroyMetalLayer(WindowInfo* wi)
{
	if (![NSThread isMainThread])
	{
		dispatch_sync_f(dispatch_get_main_queue(), wi,
			[](void* ctx) { DestroyMetalLayer(static_cast<WindowInfo*>(ctx)); });
		return;
	}

	// Releases our retain. The layer itself belongs to the view and
	// outlives this, which is the difference from the AppKit original.
	CAMetalLayer* layer = (__bridge_transfer CAMetalLayer*)wi->surface_handle;
	(void)layer;
	wi->surface_handle = nullptr;
}

std::optional<float> CocoaTools::GetViewRefreshRate(const WindowInfo& wi)
{
	if (![NSThread isMainThread])
	{
		std::optional<float> ret;
		dispatch_sync(dispatch_get_main_queue(), [&ret, &wi] { ret = GetViewRefreshRate(wi); });
		return ret;
	}

	UIView* const view = (__bridge UIView*)wi.window_handle;
	UIScreen* const screen = [[[view window] windowScene] screen];
	if (!screen)
		return std::nullopt;

	const NSInteger fps = [screen maximumFramesPerSecond];
	if (fps <= 0)
		return std::nullopt;

	return static_cast<float>(fps);
}

// MARK: - Things Cabinet owns instead

void CocoaTools::MarkHelpMenu(void* menu)
{
	// The menu bar is Cabinet's, built in MacMenus.swift.
}

bool Common::PlaySoundAsync(const char* path)
{
	// NSSound is AppKit. Nothing in the player asks for this.
	return false;
}

// MARK: - Paths

std::optional<std::string> CocoaTools::GetBundlePath()
{
	std::optional<std::string> ret;
	@autoreleasepool
	{
		NSURL* url = [NSURL fileURLWithPath:[[NSBundle mainBundle] bundlePath]];
		if (url)
			ret = std::string([url fileSystemRepresentation]);
	}
	return ret;
}

std::optional<std::string> CocoaTools::GetNonTranslocatedBundlePath()
{
	// Translocation happens to quarantined bundles run from a disk
	// image or the Downloads folder. Cabinet is an installed app, and
	// the Security call the original used to undo it is not on
	// Catalyst, so the bundle path is the answer.
	return GetBundlePath();
}

std::optional<std::string> CocoaTools::GetResourcePath()
{
	@autoreleasepool
	{
		if (NSBundle* bundle = [NSBundle mainBundle])
		{
			NSString* rsrc = [bundle resourcePath];
			NSString* root = [bundle bundlePath];
			if ([rsrc isEqualToString:root])
				rsrc = [rsrc stringByAppendingString:@"/resources"];
			return std::string([rsrc UTF8String]);
		}
	}
	return std::nullopt;
}

std::optional<std::string> CocoaTools::MoveToTrash(std::string_view file)
{
	NSURL* url = [NSURL fileURLWithPath:NSStringFromStringView(file)];
	NSURL* new_url = nil;
	if (![[NSFileManager defaultManager] trashItemAtURL:url resultingItemURL:&new_url error:nil])
		return std::nullopt;
	return std::string([new_url fileSystemRepresentation]);
}

bool CocoaTools::DelayedLaunch(std::string_view file)
{
	// PCSX2's own updater relaunching itself. Cabinet updates as one app.
	return false;
}

bool CocoaTools::ShowInFinder(std::string_view file)
{
	// NSWorkspace is AppKit.
	return false;
}

// MARK: - The GSRunner window, which Cabinet supplies instead

void* CocoaTools::CreateWindow(std::string_view title, u32 width, u32 height)
{
	return nullptr;
}

void CocoaTools::DestroyWindow(void* window)
{
}

void CocoaTools::GetWindowInfoFromWindow(WindowInfo* wi, void* window)
{
	wi->type = WindowInfo::Type::Surfaceless;
}

void CocoaTools::RunCocoaEventLoop(bool forever)
{
	// Cabinet's UIApplication is already running one.
}

void CocoaTools::StopMainThreadEventLoop()
{
}
