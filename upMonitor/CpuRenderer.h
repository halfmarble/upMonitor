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
// CPU from the left; in Dot style three dots as the graph's), then a clear gap before the core graph; any number of
// extra readings that a build adds are drawn in the same way at the right of the image, after the core graph and a gap
// as wide. The three may be left out (extraOnly): the core graph then starts at x = 0, with the extra readings, when
// there are any, at the right as before. The extra readings fall into groups: a reading that starts a group is drawn
// after a further clear gap, CPU_RENDER_GROUP_GAP wide, and the first reading is always the first of its group. An
// extra reading may also carry a mark, a 1-pt line across its bar at that height, an alert, which draws its bar whole,
// without the dashes, a pace, how much of the bar's period has passed, and a tint, which paints its bar as a bar at
// another load would be, its height unchanged; with colour, the part of a bar above its pace, and all of an alert bar
// with no pace, is painted grey
#define CPU_RENDER_READINGS_COUNT (3)
#define CPU_RENDER_READINGS_GAP (4.0)
#define CPU_RENDER_EXTRA_GAP CPU_RENDER_READINGS_GAP
#define CPU_RENDER_GROUP_GAP CPU_RENDER_EXTRA_GAP

// one extra reading, as the bars of the extra block are drawn from left to right
struct CpuExtraReading
{
  // 0..1; below 0, not read: only the bar's background is drawn, and in Dot style nothing
  double value;
  // a share of its bar's height (from where a dashed bar starts): a 1-pt line across the bar at that height, white on a
  // dark menu bar and black on a light one, over the dashes; none in Dot style, and drawn only above 0, so a zeroed
  // struct has none
  double mark;
  // a share of its bar's height, 0..1 (above 1 as 1), as mark: how much of its period has passed. Above 0, in bar style
  // with colour: a bar above it is painted in two, up to pace in its ramp's coolest colour and from pace up in grey,
  // the marks' colour at half opacity over its background (halfway between it and the mark's line); a bar below it has
  // the stretch from its top up to pace painted dim in its own colour. Nothing in Dot style or without colour, and 0 or
  // below (NaN too) is the default, so a zeroed struct has none
  double pace;
  // above 0: in bar style the bar is painted as a bar at that load (0..1, above 1 as 1) would be, in its ramp colour and
  // opacity, its height still value's; 0 or below (NaN too) is the default: painted by its value. Nothing changes in Dot
  // style or for a bar not read, so a zeroed struct has none
  double tint;
  // true: this reading is painted in colorRed, colorGreen and colorBlue (sRGB, each 0..1) in place of its ramp colour,
  // tint and pace, and of an alert's grey: in bar style its fill opaque and its background, drawn also while it is not
  // read, at the dim opacity of the pace's stretch (0.25 light, 0.35 dark); in Dot style a read reading's dot. Only
  // with colour; false is the default, so a zeroed struct has none
  bool hasColor;
  double colorRed, colorGreen, colorBlue;
  // true: this reading's dashed bar is drawn whole, without the dashes, in its own colour (its tint's when it has one);
  // in bar style with colour, a bar with no pace above 0 and no colour of its own (hasColor) is painted all in the
  // pace's grey instead, dashed or solid (with a pace, the pace paints it, and a bar at or below its pace keeps its
  // colour); nothing changes in Dot style; false is the default
  bool alert;
  // true: this reading starts a new group, after a clear gap; false is the default, and the first reading's flag is
  // ignored
  bool groupStart;
  // true: this reading is drawn as a core bar, as wide as the tickWidth given and in a core bar's slot (tickTotalWidth);
  // false is the default: twice as wide, in the readings' slot. Dot style does not change
  bool narrow;
} typedef CpuExtraReading;

// each 0..1; below 0, not read: only the bar's background is drawn, and in Dot style nothing
struct CpuReadings
{
  double cpu;
  double memory;
  double disk;
  int extraCount; // 0 or more (below 0 counts as 0), the first extraCount of extra drawn
  // extraCount entries; NULL: every extra reading is not read, with no mark, no alert and one group
  const CpuExtraReading* extra;
  // true: the three readings and their block are not drawn, only the extra readings (false is the default)
  bool extraOnly;
} typedef CpuReadings;

void CpuRenderInit(void);
// the width the readings block and its gap add to the image, and the extra readings' block with its gap, for the core
// graph's style, bar width and tick spacing, with extraCount extra readings, extra giving their groups (NULL: one group)
CGFloat CpuRenderReadingsWidth(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, int extraCount, const CpuExtraReading* extra);
// the width the extra readings' block with its gap adds to the image, with extraCount extra readings and their groups;
// 0 with none
CGFloat CpuRenderExtraWidth(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, int extraCount, const CpuExtraReading* extra);
// the slot width of reading index in an image with extraCount extra readings: the readings' slot for the three, an extra
// reading's own for the others, which is a core bar's when it is narrow (extra NULL: none is)
CGFloat CpuRenderReadingSlot(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, int extraCount, const CpuExtraReading* extra, int index);
// the x step from one of the three readings, or one extra reading that is not narrow, to the next (disk at 0, memory at one step, CPU at two; the extra readings,
// right of the core graph, the same step apart; a narrow extra reading's step is a core bar's, a group's gap is added
// where a group starts)
CGFloat CpuRenderReadingsSlot(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth);
// where reading index starts in an image imageWidth wide with extraCount extra readings and their groups: the three
// readings index slots from the left, the extra ones (index CPU_RENDER_READINGS_COUNT on) after the core graph and its
// gap, each group's gap added where a group starts; an index past the last extra reading gives the last one's x
CGFloat CpuRenderReadingX(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, CGFloat imageWidth, int extraCount, const CpuExtraReading* extra, int index);
// where the core graph starts and ends in an image imageWidth wide: after the readings block and its gap when the three
// readings are drawn (readings), else at x = 0; before the extra readings' block (extraCount and extra, read with or
// without the three)
void CpuRenderGraphSpan(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, CGFloat imageWidth, bool readings, int extraCount, const CpuExtraReading* extra, CGFloat* start, CGFloat* end);
// readings NULL: no block, the core graph starts at x = 0; else it starts after the block and the gap, unless
// readings->extraOnly leaves the three out
void CpuRender(CpuSummaryInfo* cpu_info, CGContextRef ctx, bool light, int granularity, bool bar, bool stripped, bool colored, CGFloat tickWidth, CGFloat tickTotalWidth, CGFloat imageWidth, int theme, const CpuReadings* readings);
void CpuRenderDemo(CGContextRef ctx, CGFloat width, CGFloat height, int tint);

__END_DECLS

#endif /* CpuRenderer_h */
