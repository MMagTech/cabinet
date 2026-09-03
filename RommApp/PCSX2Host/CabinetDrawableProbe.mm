// See CabinetDrawableProbe.h.

#if !__has_feature(objc_arc)
	#error "Compile this with -fobjc-arc"
#endif

#include "CabinetDrawableProbe.h"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include <sys/stat.h>

namespace
{
	std::mutex s_log_lock;
	FILE* s_log = nullptr;
	std::string s_dir;
	std::atomic<uint32_t> s_frame{0};

	const char* ProbeEnv()
	{
		static const char* v = getenv("CABINET_DRAWABLE_PROBE");
		return v;
	}

	bool ProbeOn()
	{
		return ProbeEnv() != nullptr;
	}

	const std::string& ProbeDir()
	{
		static std::string dir = [] {
			std::string d;
			const char* v = ProbeEnv();
			if (v && strcmp(v, "1") != 0)
				d = v;
			else if (const char* home = getenv("HOME"))
				d = std::string(home) + "/Documents/Cabinet/PS2/logs";
			mkdir(d.c_str(), 0755);
			return d;
		}();
		return dir;
	}

	void Log(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
	void Log(const char* fmt, ...)
	{
		char line[2048];
		va_list ap;
		va_start(ap, fmt);
		vsnprintf(line, sizeof(line), fmt, ap);
		va_end(ap);

		std::lock_guard<std::mutex> lock(s_log_lock);
		if (!s_log)
		{
			const std::string path = ProbeDir() + "/drawable-probe.log";
			s_log = fopen(path.c_str(), "w");
		}
		fprintf(stderr, "[PROBE] %s\n", line);
		if (s_log)
		{
			fprintf(s_log, "%s\n", line);
			fflush(s_log);
		}
	}

	const char* StatusName(MTLCommandBufferStatus s)
	{
		switch (s)
		{
			case MTLCommandBufferStatusNotEnqueued: return "NotEnqueued";
			case MTLCommandBufferStatusEnqueued: return "Enqueued";
			case MTLCommandBufferStatusCommitted: return "Committed";
			case MTLCommandBufferStatusScheduled: return "Scheduled";
			case MTLCommandBufferStatusCompleted: return "Completed";
			case MTLCommandBufferStatusError: return "ERROR";
		}
		return "?";
	}

	std::string Describe(id obj)
	{
		if (!obj)
			return "(nil)";
		return std::string([[obj description] UTF8String]);
	}

	// Whole-texture stats, plus an 8x6 brightness map so the log alone
	// says whether the picture is there, half there, or gone.
	void Analyse(uint32_t frame, id<MTLTexture> tex, bool dump)
	{
		const NSUInteger w = [tex width], h = [tex height];
		const MTLPixelFormat fmt = [tex pixelFormat];
		const bool bgra = fmt == MTLPixelFormatBGRA8Unorm || fmt == MTLPixelFormatBGRA8Unorm_sRGB;
		const bool rgba = fmt == MTLPixelFormatRGBA8Unorm || fmt == MTLPixelFormatRGBA8Unorm_sRGB;
		if (!bgra && !rgba)
		{
			Log("frame %u: staging format %lu is not 8-bit BGRA/RGBA, no stats", frame, (unsigned long)fmt);
			return;
		}

		const NSUInteger bpr = w * 4;
		std::vector<uint8_t> px(bpr * h);
		[tex getBytes:px.data() bytesPerRow:bpr fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];

		uint64_t lit = 0, sum = 0, asum = 0, aopaque = 0, azero = 0;
		uint8_t maxv = 0;
		const int gw = 8, gh = 6;
		uint64_t grid[gh][gw] = {};
		uint64_t gridn[gh][gw] = {};
		for (NSUInteger y = 0; y < h; y++)
		{
			const uint8_t* row = px.data() + y * bpr;
			const int gy = (int)(y * gh / h);
			for (NSUInteger x = 0; x < w; x++)
			{
				const uint8_t* p = row + x * 4;
				const uint8_t m = std::max(p[0], std::max(p[1], p[2]));
				if (m > 8)
					lit++;
				sum += m;
				if (m > maxv)
					maxv = m;
				asum += p[3];
				if (p[3] == 255)
					aopaque++;
				else if (p[3] == 0)
					azero++;
				const int gx = (int)(x * gw / w);
				grid[gy][gx] += m;
				gridn[gy][gx]++;
			}
		}
		const uint8_t* c = px.data() + (h / 2) * bpr + (w / 2) * 4;
		Log("frame %u: %lux%lu fmt=%lu lit=%.1f%% mean=%.1f max=%u centre=(%u,%u,%u,%u) alpha: mean=%.1f opaque=%.1f%% zero=%.1f%%",
			frame, (unsigned long)w, (unsigned long)h, (unsigned long)fmt,
			100.0 * (double)lit / (double)(w * h), (double)sum / (double)(w * h), maxv,
			c[0], c[1], c[2], c[3],
			(double)asum / (double)(w * h), 100.0 * (double)aopaque / (double)(w * h), 100.0 * (double)azero / (double)(w * h));
		for (int gy = 0; gy < gh; gy++)
		{
			char line[64];
			int n = 0;
			for (int gx = 0; gx < gw; gx++)
				n += snprintf(line + n, sizeof(line) - n, "%3u ", (unsigned)(grid[gy][gx] / std::max<uint64_t>(1, gridn[gy][gx])));
			Log("frame %u:   %s", frame, line);
		}

		if (!dump)
			return;
		char name[64];
		snprintf(name, sizeof(name), "/drawable-%05u.ppm", frame);
		const std::string path = ProbeDir() + name;
		if (FILE* f = fopen(path.c_str(), "wb"))
		{
			const NSUInteger step = 4, dw = w / step, dh = h / step;
			fprintf(f, "P6\n%lu %lu\n255\n", (unsigned long)dw, (unsigned long)dh);
			std::vector<uint8_t> rgb(dw * 3);
			for (NSUInteger y = 0; y < dh; y++)
			{
				const uint8_t* row = px.data() + y * step * bpr;
				for (NSUInteger x = 0; x < dw; x++)
				{
					const uint8_t* p = row + x * step * 4;
					rgb[x * 3 + 0] = bgra ? p[2] : p[0];
					rgb[x * 3 + 1] = p[1];
					rgb[x * 3 + 2] = bgra ? p[0] : p[2];
				}
				fwrite(rgb.data(), 1, rgb.size(), f);
			}
			fclose(f);
			Log("frame %u: wrote %s", frame, path.c_str());
		}
		else
		{
			Log("frame %u: could not write %s", frame, path.c_str());
		}
	}
} // namespace

void CabinetProbeConfigureLayer(CAMetalLayer* layer, UIView* view)
{
	if (!ProbeOn())
		return;

	if (const char* fb = getenv("CABINET_LAYER_FBONLY"))
	{
		const BOOL want = atoi(fb) != 0;
		[layer setFramebufferOnly:want];
		Log("layer: framebufferOnly forced to %d", (int)want);
	}

	if (const char* op = getenv("CABINET_LAYER_OPAQUE"))
	{
		[layer setOpaque:atoi(op) != 0];
		Log("layer: opaque forced to %d", atoi(op) != 0);
	}

	Log("layer: class=%s framebufferOnly=%d pixelFormat=%lu drawableSize=%.0fx%.0f bounds=%.1fx%.1f frame=(%.1f,%.1f %.1fx%.1f) contentsScale=%.2f",
		object_getClassName(layer), (int)[layer framebufferOnly], (unsigned long)[layer pixelFormat],
		[layer drawableSize].width, [layer drawableSize].height,
		[layer bounds].size.width, [layer bounds].size.height,
		[layer frame].origin.x, [layer frame].origin.y, [layer frame].size.width, [layer frame].size.height,
		[layer contentsScale]);
	Log("layer: opaque=%d hidden=%d opacity=%.2f masksToBounds=%d maximumDrawableCount=%lu presentsWithTransaction=%d allowsNextDrawableTimeout=%d displaySyncEnabled=%d",
		(int)[layer isOpaque], (int)[layer isHidden], [layer opacity], (int)[layer masksToBounds],
		(unsigned long)[layer maximumDrawableCount], (int)[layer presentsWithTransaction],
		(int)[layer allowsNextDrawableTimeout], (int)[layer displaySyncEnabled]);
	Log("layer: wantsEDR=%d colorspace=%s contentsGravity=%s needsDisplayOnBoundsChange=%d drawsAsynchronously=%d contents=%s superlayer=%s sublayers=%lu",
		(int)[layer wantsExtendedDynamicRangeContent],
		[layer colorspace] ? Describe((__bridge id)[layer colorspace]).c_str() : "(nil)",
		[[layer contentsGravity] UTF8String], (int)[layer needsDisplayOnBoundsChange],
		(int)[layer drawsAsynchronously], [layer contents] ? object_getClassName([layer contents]) : "(nil)",
		[layer superlayer] ? object_getClassName([layer superlayer]) : "(nil)",
		(unsigned long)[[layer sublayers] count]);
	Log("layer: device=%s", [layer device] ? [[[layer device] name] UTF8String] : "(nil)");

	if (view)
	{
		Log("view: class=%s window=%d superview=%s bounds=%.1fx%.1f hidden=%d alpha=%.2f opaque=%d contentScaleFactor=%.2f layer==view.layer=%d",
			object_getClassName(view), [view window] != nil,
			[view superview] ? object_getClassName([view superview]) : "(nil)",
			[view bounds].size.width, [view bounds].size.height,
			(int)[view isHidden], [view alpha], (int)[view isOpaque], [view contentScaleFactor],
			(int)([view layer] == layer));
		UIWindow* win = [view window];
		if (win)
			Log("window: class=%s screen.scale=%.2f keyWindow=%d hidden=%d bounds=%.1fx%.1f",
				object_getClassName(win), [[win screen] scale], (int)[win isKeyWindow], (int)[win isHidden],
				[win bounds].size.width, [win bounds].size.height);
	}
}

void CabinetProbePresent(id<MTLCommandBuffer> buf, id<CAMetalDrawable> drawable, CAMetalLayer* layer, id<MTLDevice> dev)
{
	if (!ProbeOn() || !drawable)
		return;

	const uint32_t frame = s_frame++;
	const bool verbose = frame < 8 || (frame % 60) == 0;
	const bool dump = (frame % 120) == 0;
	id<MTLTexture> tex = [drawable texture];

	if (verbose)
		Log("frame %u: drawable id=%lu tex=%lux%lu fmt=%lu usage=%lu storage=%lu tex.framebufferOnly=%d layer.framebufferOnly=%d layer.drawableSize=%.0fx%.0f cmdbuf=%s",
			frame, (unsigned long)[drawable drawableID], (unsigned long)[tex width], (unsigned long)[tex height],
			(unsigned long)[tex pixelFormat], (unsigned long)[tex usage], (unsigned long)[tex storageMode],
			(int)[tex isFramebufferOnly], (int)[layer framebufferOnly],
			[layer drawableSize].width, [layer drawableSize].height,
			[[buf label] UTF8String] ?: "(none)");

	id<MTLTexture> staging = nil;
	if (verbose && ![tex isFramebufferOnly])
	{
		static id<MTLTexture> s_staging = nil;
		if (!s_staging || [s_staging width] != [tex width] || [s_staging height] != [tex height] || [s_staging pixelFormat] != [tex pixelFormat])
		{
			MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:[tex pixelFormat]
				width:[tex width] height:[tex height] mipmapped:NO];
			desc.storageMode = MTLStorageModeShared;
			desc.usage = MTLTextureUsageShaderRead;
			s_staging = [dev newTextureWithDescriptor:desc];
			Log("frame %u: staging texture %lux%lu created=%d", frame, (unsigned long)[tex width], (unsigned long)[tex height], s_staging != nil);
		}
		staging = s_staging;
		if (staging)
		{
			id<MTLBlitCommandEncoder> blit = [buf blitCommandEncoder];
			[blit setLabel:@"Cabinet drawable probe"];
			[blit copyFromTexture:tex toTexture:staging];
			[blit endEncoding];
		}
	}
	else if (verbose)
	{
		Log("frame %u: drawable is framebufferOnly, no readback (set CABINET_LAYER_FBONLY=0)", frame);
	}

	[drawable addPresentedHandler:^(id<MTLDrawable> d) {
		if (verbose)
			Log("frame %u: PRESENTED id=%lu presentedTime=%.6f", frame, (unsigned long)[d drawableID], [d presentedTime]);
	}];

	[buf addCompletedHandler:^(id<MTLCommandBuffer> b) {
		NSError* err = [b error];
		const MTLCommandBufferStatus st = [b status];
		if (verbose || st != MTLCommandBufferStatusCompleted || err)
			Log("frame %u: cmdbuf '%s' status=%s error=%s gpu=%.3fms",
				frame, [[b label] UTF8String] ?: "(none)", StatusName(st),
				err ? [[err description] UTF8String] : "(none)",
				([b GPUEndTime] - [b GPUStartTime]) * 1000.0);
		if (staging && st == MTLCommandBufferStatusCompleted)
			Analyse(frame, staging, dump);
	}];
}

void CabinetProbeCommandBuffer(id<MTLCommandBuffer> buf)
{
	if (!ProbeOn() || !buf)
		return;
	[buf addCompletedHandler:^(id<MTLCommandBuffer> b) {
		NSError* err = [b error];
		if ([b status] != MTLCommandBufferStatusCompleted || err)
			Log("cmdbuf '%s' status=%s error=%s", [[b label] UTF8String] ?: "(none)",
				StatusName([b status]), err ? [[err description] UTF8String] : "(none)");
	}];
}
