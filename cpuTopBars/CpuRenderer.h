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

// the readings block at the left of the image, five bars drawn as the core graph's but twice as wide (disk, memory,
// CPU, the E-cores' CPU and the P-cores' CPU from the left; in Dot style five dots as the graph's), then a clear gap
// before the core graph. When the graph splits into the E-cores' bars and then the P-cores' (efficiencyBars above 0, the
// count of the graph's bars that are E-cores', CpuRenderEfficiencyBars), the E-cores' and the P-cores' readings each head
// their own cores instead: disk, memory and CPU, the gap, the E-cores' reading and their bars, a group gap, the P-cores'
// reading and their bars; the image is a group gap wider (in Dot style 1 pt more, the last E-core dot's overhang). Any
// number of extra readings that a build adds are drawn in the same way at the right of the
// image, after the core graph and a gap as wide. The five may be left out (extraOnly): the core graph then starts at x = 0, with the extra readings, when
// there are any, at the right as before. The extra readings fall into groups: a reading that starts a group is drawn
// after a further clear gap, CPU_RENDER_GROUP_GAP wide, and the first reading is always the first of its group. An
// extra reading may also carry a mark, a 1-pt line across its bar at that height, an alert, which draws its bar whole,
// without the dashes, a pace, how much of the bar's period has passed, and a tint, which paints its bar as a bar at
// another load would be, its fill opaque with colour, its height unchanged; with colour, the part of a bar above its
// pace, and all of an alert bar with no pace, is painted in its ramp's hottest colour. With the GPU's readings
// (gpuShown), the block holds seven: disk, memory, CPU, the GPU's bar, the Neural Engine's, then the E-cores' and the
// P-cores' readings, each index one slot, so the image is two readings' slots wider and every reading after CPU, the
// core graph and the extra readings two slots further right
#define CPU_RENDER_READINGS_COUNT (5) // the readings without the GPU's, and the first extra reading's index then
#define CPU_RENDER_READINGS_COUNT_GPU (7) // with the GPU's bar and the Neural Engine's
#define CPU_RENDER_READING_EFFICIENCY (3) // the E-cores' CPU's index among the readings, without the GPU's
#define CPU_RENDER_READING_PERFORMANCE (4) // the P-cores' CPU's, without the GPU's
#define CPU_RENDER_READING_GPU (3) // with them, the GPU's bar's index
#define CPU_RENDER_READING_NEURAL_ENGINE (4) // and the Neural Engine's
#define CPU_RENDER_READINGS_GAP (4.0)
#define CPU_RENDER_EXTRA_GAP CPU_RENDER_READINGS_GAP
#define CPU_RENDER_GROUP_GAP CPU_RENDER_EXTRA_GAP
#define CPU_RENDER_THIN_FROM (24) // core bars past this many are drawn thinner, so the core graph keeps about this many slots' width

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
  // with colour: a bar above it is painted in two, up to pace in its ramp's coolest colour and from pace up in its
  // ramp's hottest colour; a bar below it has the stretch from its top up to pace painted dim in its own colour.
  // Nothing in Dot style or without colour, and 0 or below (NaN too) is the default, so a zeroed struct has none
  double pace;
  // above 0: in bar style the bar is painted as a bar at that load (0..1, above 1 as 1) would be, in its ramp colour, its
  // fill opaque with colour and at that load's opacity without, its height still value's; 0 or below (NaN too) is the
  // default: painted by its value. Nothing changes in Dot style or for a bar not read, so a zeroed struct has none
  double tint;
  // true: this reading is painted in colorRed, colorGreen and colorBlue (sRGB, each 0..1) in place of its ramp colour,
  // tint and pace, and of an alert's hottest colour: in bar style its fill opaque and its background, drawn also while
  // it is not read, at the dim opacity of the pace's stretch (0.25 light, 0.35 dark); in Dot style a read reading's
  // dot. Only with colour; false is the default, so a zeroed struct has none
  bool hasColor;
  double colorRed, colorGreen, colorBlue;
  // true: this reading's dashed bar is drawn whole, without the dashes, in its own colour (its tint's when it has one);
  // in bar style with colour, a bar with no pace above 0 and no colour of its own (hasColor) is painted all in its
  // ramp's hottest colour instead, dashed or solid (with a pace, the pace paints it, and a bar at or below its pace keeps its
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
  double efficiency; // the E-cores' CPU
  double performance; // the P-cores' CPU
  int extraCount; // 0 or more (below 0 counts as 0), the first extraCount of extra drawn
  // extraCount entries; NULL: every extra reading is not read, with no mark, no alert and one group
  const CpuExtraReading* extra;
  // true: the five readings and their block are not drawn, only the extra readings (false is the default)
  bool extraOnly;
  // above 0: the graph splits after this many bars, the E-cores', and the E-cores' and P-cores' readings head their own
  // bars (CpuRenderEfficiencyBars, for the granularity drawn); 0 is the default: the five readings in one block. Ignored
  // when the five are not drawn
  int efficiencyBars;
  // the GPU's busy share, 0..1; below 0, not read, as the five. Drawn only with gpuShown
  double gpu;
  // the Neural Engine's power: 1 on, filled in the menu bar's text colour (white on a dark menu bar, black on a light
  // one) at 0.9 opacity; 0 off; below 0, not read: nothing in its slot. In bar style a wide bar drawn whole, without the
  // dashes: on, solid; off, only the bars' background. In Dot style a dot: on, filled; off, a 1-pt ring at the bars'
  // background opacity. Drawn only with gpuShown, never in the ramp's colours
  int neuralEngine;
  // true: neuralEngineBusy, not neuralEngine, sets the Neural Engine's bar: its background, and over it a fill
  // neuralEngineBusy (0..1) of its height, in the same colour, whole, without the dashes; in Dot style a dot filled while
  // the share is 0.005 or more, else the ring. false is the default, so a zeroed struct draws neuralEngine as before
  bool neuralEngineByShare;
  double neuralEngineBusy;
  // true: the GPU's bar and the Neural Engine's are drawn after CPU, CPU_RENDER_READINGS_COUNT_GPU readings in all;
  // false is the default, so a zeroed struct draws the five as before. Ignored when the five are not drawn
  bool gpuShown;
} typedef CpuReadings;

void CpuRenderInit(void);
// the readings block's count, and the E-cores' and the P-cores' readings' indices, without the GPU's readings or with
// them (gpuShown): 5, 3 and 4, or 7, 5 and 6; the first extra reading's index is the count
int CpuRenderReadingsCount(bool gpuShown);
int CpuRenderReadingEfficiency(bool gpuShown);
int CpuRenderReadingPerformance(bool gpuShown);
// how many of the core graph's bars at granularity are the E-cores', when the graph splits into them and then the
// P-cores': kinds (countLogical of 'E' or 'P', CpuSamplerGetKinds) all E-cores' first and then all P-cores', both
// present, and each bar's CPUs of one kind; 0 when it does not split (one bar, kinds NULL, any other order)
int CpuRenderEfficiencyBars(int granularity, natural_t countLogical, const char* kinds);
// the width the readings block and its gap add to the image, and the extra readings' block with its gap, for the core
// graph's style, bar width and tick spacing, with the GPU's readings or without (gpuShown), the split after
// efficiencyBars bars (0: none), with extraCount extra readings, extra giving their groups (NULL: one group)
CGFloat CpuRenderReadingsWidth(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, bool gpuShown, int efficiencyBars, int extraCount, const CpuExtraReading* extra);
// the width the extra readings' block with its gap adds to the image, with extraCount extra readings and their groups;
// 0 with none
CGFloat CpuRenderExtraWidth(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, int extraCount, const CpuExtraReading* extra);
// the slot width of reading index in an image with extraCount extra readings: the readings' slot for the block's
// readings (CpuRenderReadingsCount(gpuShown) of them), an extra reading's own for the others, which is a full core bar's
// slot when it is narrow (extra NULL: none is)
CGFloat CpuRenderReadingSlot(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, bool gpuShown, int extraCount, const CpuExtraReading* extra, int index);
// the x step from one of the block's readings, or one extra reading that is not narrow, to the next (disk at 0, memory at one step, CPU at two, then the E-cores' and the P-cores', or the GPU's,
// the Neural Engine's, the E-cores' and the P-cores', one step each, unless the graph splits, CpuRenderReadingX; the extra readings,
// right of the core graph, the same step apart; a narrow extra reading's step is a full core bar's slot, a group's gap is added
// where a group starts)
CGFloat CpuRenderReadingsSlot(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth);
// where reading index starts in an image imageWidth wide with extraCount extra readings and their groups: the block's
// readings (CpuRenderReadingsCount(gpuShown)) index slots from the left (split after efficiencyBars bars: the E-cores'
// before their bars, the P-cores' before theirs), the extra ones (index CpuRenderReadingsCount(gpuShown) on) after the
// core graph and its gap, each group's gap added where a group starts; an index past the last extra reading gives the
// last one's x
CGFloat CpuRenderReadingX(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, bool gpuShown, CGFloat imageWidth, int efficiencyBars, natural_t cores, int extraCount, const CpuExtraReading* extra, int index);
// where the core graph starts and ends in an image imageWidth wide: after the readings block and its gap when the five
// readings are drawn (readings; with the GPU's two more, gpuShown), else at x = 0; split after efficiencyBars bars, from
// the first E-core bar, past the P-cores' reading, to the last P-core bar; before the extra readings' block (extraCount
// and extra, read with or without the five)
void CpuRenderGraphSpan(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, CGFloat imageWidth, bool readings, bool gpuShown, int efficiencyBars, int extraCount, const CpuExtraReading* extra, CGFloat* start, CGFloat* end);
// a core bar's slot with count core bars: tickTotalWidth up to CPU_RENDER_THIN_FROM bars; past it, the largest whole
// number of points that keeps the graph within CPU_RENDER_THIN_FROM slots, but never less than a 1-pt bar and the full
// slot's gap (tickTotalWidth - tickWidth), so a graph of many cores grows past that width. Dots keep theirs
CGFloat CpuRenderCoreSlot(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, natural_t count);
// the width a core bar is drawn with count core bars: tickWidth in a full slot, else its slot less the same gap (at
// least 1 pt). The readings keep tickWidth and tickTotalWidth whatever the count
CGFloat CpuRenderCoreWidth(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, natural_t count);
// where the core graph's bar index of count is drawn, the graph starting at start (CpuRenderGraphSpan): a core bar's
// slot per bar, the P-cores' bars (index efficiencyBars on, when above 0) after the split's gap and the P-cores' reading
CGFloat CpuRenderCoreX(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, CGFloat start, int efficiencyBars, int count, int index);
// the core graph's bar whose slot (CpuRenderCoreX, a core bar's slot wide) holds x, of count bars; the last bar's
// reaches on past its slot (Dot style's overhang, the clear space right of the graph); -1 left of the first bar, and
// between the last E-core bar's slot and the first P-core bar (the split's gap and the P-cores' reading)
int CpuRenderCoreAtX(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, CGFloat start, int efficiencyBars, int count, CGFloat x);
// readings NULL: no block, the core graph starts at x = 0; else it starts after the block and the gap, unless
// readings->extraOnly leaves the five out
void CpuRender(CpuSummaryInfo* cpu_info, CGContextRef ctx, bool light, int granularity, bool bar, bool stripped, bool colored, CGFloat tickWidth, CGFloat tickTotalWidth, CGFloat imageWidth, int theme, const CpuReadings* readings);
void CpuRenderDemo(CGContextRef ctx, CGFloat width, CGFloat height, int tint);

__END_DECLS

#endif /* CpuRenderer_h */
