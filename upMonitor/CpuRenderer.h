// The MIT License (MIT)

// Copyright 2022 HalfMarble LLC

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#ifndef CpuRenderer_h
#define CpuRenderer_h

#include <stdio.h>
#include <CoreGraphics/CoreGraphics.h>

#include "CpuSampler.h"

__BEGIN_DECLS

enum Theme
{
  THEME_YELLOW = 0,
  THEME_GREEN,
  THEME_BLUE,
};

// the readings block at the left of the image, three bars drawn as the core graph's but twice as wide (disk, memory,
// CPU from the left; in Dot style three dots as the graph's), then up to CPU_RENDER_EXTRA_MAX extra readings that a
// build adds, drawn after the CPU bar in the same way, then a clear gap before the core graph
#define CPU_RENDER_READINGS_COUNT (3)
#define CPU_RENDER_EXTRA_MAX (4)
#define CPU_RENDER_READINGS_GAP (4.0)

// each 0..1; below 0, not read: only the bar's background is drawn, and in Dot style nothing
struct CpuReadings
{
  double cpu;
  double memory;
  double disk;
  int extraCount; // 0..CPU_RENDER_EXTRA_MAX, the first extraCount of extra drawn
  double extra[CPU_RENDER_EXTRA_MAX];
} typedef CpuReadings;

void CpuRenderInit(void);
// the width the readings block and its gap add to the image, for the core graph's style, bar width and tick spacing,
// with extraCount extra readings (clamped to 0..CPU_RENDER_EXTRA_MAX)
CGFloat CpuRenderReadingsWidth(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, int extraCount);
// the x step from one reading to the next (disk at 0, memory at one step, CPU at two, the extra readings after it)
CGFloat CpuRenderReadingsSlot(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth);
// readings NULL: no block, the core graph starts at x = 0; else it starts after the block and the gap
void CpuRender(CpuSummaryInfo* cpu_info, CGContextRef ctx, bool light, int granularity, bool bar, bool stripped, bool colored, CGFloat tickWidth, CGFloat tickTotalWidth, CGFloat imageWidth, int theme, const CpuReadings* readings);
void CpuRenderDemo(CGContextRef ctx, CGFloat width, CGFloat height, int tint);

__END_DECLS

#endif /* CpuRenderer_h */
