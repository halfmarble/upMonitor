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

#include "CpuRenderer.h"

#include <math.h>
#include <CoreText/CoreText.h>

// red, green and blue, each 0..1
typedef struct
{
  double r, g, b;
}
rgb;

// hue in degrees; saturation and value 0..1
typedef struct
{
  double h, s, v;
}
hsv;

typedef struct
{
  double x;
  double y;
}
point;

#define N_SEG 512
static point easing[N_SEG+1];
static void _cubic_bezier(double x1, double y1, double x2, double y2, double x3, double y3, double x4, double y4)
{
  for (int i=0; i <= N_SEG; ++i)
  {
    double t = (double)i / (double)N_SEG;
    
    double a = pow((1.0 - t), 3.0);
    double b = 3.0 * t * pow((1.0 - t), 2.0);
    double c = 3.0 * pow(t, 2.0) * (1.0 - t);
    double d = pow(t, 3.0);
    
    double x = a * x1 + b * x2 + c * x3 + d * x4;
    double y = a * y1 + b * y2 + c * y3 + d * y4;
    easing[i].x = x;
    easing[i].y = y;
  }
}

// value 0..1; anything outside, NaN included, is clamped, so the index stays inside the table
static inline double _ease(double value)
{
  if (!(value > 0.0))
  {
    return easing[0].y;
  }
  if (value >= 1.0)
  {
    return easing[N_SEG].y;
  }
  int index = (int)(value*N_SEG);
  return easing[index].y;
}

void CpuRenderInit(void)
{
  _cubic_bezier(0, 0, 1, 0, 0, 1, 1, 1);
}

// one channel of an HSV colour: f(n) = v - v*s*max(0, min(k, 4-k, 1)), with k = (n + h/60) mod 6;
// n = 5 gives red, 3 green, 1 blue
static double _hsv_channel(hsv in, double n)
{
  double k = fmod(n + (in.h / 60.0), 6.0);
  if (k < 0.0)
  {
    k += 6.0;
  }
  return in.v - (in.v * in.s * fmax(0.0, fmin(fmin(k, 4.0 - k), 1.0)));
}

rgb _hsv2rgb(hsv in)
{
  rgb out;
  out.r = _hsv_channel(in, 5.0);
  out.g = _hsv_channel(in, 3.0);
  out.b = _hsv_channel(in, 1.0);
  return out;
}

// https://codebeautify.org/rgb-to-hsv-converter
// rgb(1, 1, 0) -> hsv(0.1667, 1.0000, 1.0000)
// rgb(1, 0, 0) -> hsv(0.0000, 1.0000, 1.0000)

// https://www.rapidtables.com/convert/color/rgb-to-hsv.html
// rgb(1, 1, 0) -> hsv(60, 1, 1)
// rgb(1, 0, 0) -> hsv( 0, 1, 1)

// https://easings.net/en
rgb _color(int cool, double t)
{
  static const double yellow = 60;
  static const double green = 120;
  static const double blue = 240;
  
  double start = 0;
  if (cool == THEME_GREEN)
  {
    start = green;
  }
  else if (cool == THEME_BLUE)
  {
    start = blue;
  }
  else
  {
    start = yellow;
  }
  
  double h = (start-(start*_ease(t)));
  hsv hsv = {h, 1.0, 1.0};
  return _hsv2rgb(hsv);
}

// a reading's slot: a bar twice the core bars' width and the same space after it; a dot's slot as the graph's
static CGFloat _readings_slot(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth)
{
  return bar ? (tickTotalWidth + tickWidth) : tickTotalWidth;
}

CGFloat CpuRenderReadingsSlot(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth)
{
  return _readings_slot(bar, tickWidth, tickTotalWidth);
}

// the optional readings of a mask, the bits that mean one
#define SHOWN_MASK (CPU_RENDER_SHOWN_GPU | CPU_RENDER_SHOWN_WIFI | CPU_RENDER_SHOWN_BATTERY)

// whether the reading of kind is in the block with the optional readings of shown: the five that are always there, and each
// optional one with its bit; the Neural Engine's bar and the GPU's go together
static bool _kind_shown(unsigned shown, int kind)
{
  switch (kind)
  {
    case CPU_RENDER_KIND_BATTERY:
      return (shown & CPU_RENDER_SHOWN_BATTERY) != 0;
    case CPU_RENDER_KIND_WIFI:
      return (shown & CPU_RENDER_SHOWN_WIFI) != 0;
    case CPU_RENDER_KIND_NEURAL_ENGINE:
    case CPU_RENDER_KIND_GPU:
      return (shown & CPU_RENDER_SHOWN_GPU) != 0;
    case CPU_RENDER_KIND_DISK:
    case CPU_RENDER_KIND_MEMORY:
    case CPU_RENDER_KIND_CPU:
    case CPU_RENDER_KIND_EFFICIENCY:
    case CPU_RENDER_KIND_PERFORMANCE:
      return true;
    default:
      return false;
  }
}

unsigned CpuRenderReadingsShown(const CpuReadings* readings)
{
  if ((readings == NULL) || readings->extraOnly)
  {
    return 0;
  }
  return (readings->gpuShown ? CPU_RENDER_SHOWN_GPU : 0) | (readings->wifiShown ? CPU_RENDER_SHOWN_WIFI : 0) |
    (readings->batteryShown ? CPU_RENDER_SHOWN_BATTERY : 0);
}

int CpuRenderReadingIndex(unsigned shown, int kind)
{
  if (!_kind_shown(shown, kind))
  {
    return -1;
  }
  int index = 0;
  for (int k=0; k<kind; k++)
  {
    if (_kind_shown(shown, k))
    {
      index++;
    }
  }
  return index;
}

int CpuRenderReadingKind(unsigned shown, int index)
{
  int n = 0;
  for (int k=0; k<=CPU_RENDER_KIND_PERFORMANCE; k++)
  {
    if (_kind_shown(shown, k))
    {
      if (n == index)
      {
        return k;
      }
      n++;
    }
  }
  return -1;
}

// the readings block's count with the optional readings of shown; the E-cores' and the P-cores' are its last two
static int _readings_count(unsigned shown)
{
  return CPU_RENDER_READINGS_COUNT + (((shown & CPU_RENDER_SHOWN_GPU) != 0) ? 2 : 0) + (((shown & CPU_RENDER_SHOWN_WIFI) != 0) ? 1 : 0) +
    (((shown & CPU_RENDER_SHOWN_BATTERY) != 0) ? 1 : 0);
}

int CpuRenderReadingsCount(unsigned shown)
{
  return _readings_count(shown);
}

int CpuRenderReadingEfficiency(unsigned shown)
{
  return _readings_count(shown) - 2;
}

int CpuRenderReadingPerformance(unsigned shown)
{
  return _readings_count(shown) - 1;
}

static int _extra_count(int extraCount)
{
  return (extraCount < 0) ? 0 : extraCount;
}

// how many extra readings in 1..index start a group (the first reading's flag is ignored)
static int _group_starts(const CpuExtraReading* extra, int index)
{
  int starts = 0;
  if (extra)
  {
    for (int j=1; j<=index; j++)
    {
      if (extra[j].groupStart)
      {
        starts++;
      }
    }
  }
  return starts;
}

// extra reading i's slot, and the width its bar is drawn: a narrow bar (Bar style only) is a core bar's width in a core
// bar's slot, any other the readings' (twice as wide)
static CGFloat _extra_slot(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, const CpuExtraReading* extra, int i)
{
  return (bar && extra && extra[i].narrow) ? tickTotalWidth : _readings_slot(bar, tickWidth, tickTotalWidth);
}

static CGFloat _extra_bar_width(bool bar, CGFloat tickWidth, const CpuExtraReading* extra, int i)
{
  return (bar && !(extra && extra[i].narrow)) ? 2.0*tickWidth : tickWidth;
}

// the load extra reading index is painted as: its tint, 0..1, when it has one and the bars are bars, else its load
static CGFloat _extra_paint(bool bar, const CpuExtraReading* extra, int index, CGFloat load)
{
  return (bar && extra && (extra[index].tint > 0.0)) ? fmin(extra[index].tint, 1.0) : load;
}

// the opacity range extra reading index's fill spans: none when it has a tint and the bars are bars with colour, so
// that its fill is opaque, else range
static CGFloat _extra_range(bool bar, bool colored, const CpuExtraReading* extra, int index, CGFloat range)
{
  return (bar && colored && extra && (extra[index].tint > 0.0)) ? 0.0 : range;
}

// the slots of extra readings first..last-1
static CGFloat _extra_slots(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, const CpuExtraReading* extra, int first, int last)
{
  CGFloat sum = 0.0;
  for (int i=first; i<last; i++)
  {
    sum += _extra_slot(bar, tickWidth, tickTotalWidth, extra, i);
  }
  return sum;
}

// block reading index's slot: the readings' slot, and for the battery's, its number's width and 1 pt more
static CGFloat _block_slot(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, unsigned shown, int index)
{
  const CGFloat slot = _readings_slot(bar, tickWidth, tickTotalWidth);
  return (CpuRenderReadingKind(shown, index) == CPU_RENDER_KIND_BATTERY) ? (slot + CPU_RENDER_BATTERY_TEXT_WIDTH + 1.0) : slot;
}

CGFloat CpuRenderReadingSlot(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, unsigned shown, int extraCount, const CpuExtraReading* extra, int index)
{
  const int base = _readings_count(shown);
  if ((index < base) || (index - base >= _extra_count(extraCount)))
  {
    return _block_slot(bar, tickWidth, tickTotalWidth, shown, index);
  }
  return _extra_slot(bar, tickWidth, tickTotalWidth, extra, index - base);
}

// the extra readings' block at the right of the image: its gap, the slots of the readings, a group gap for each reading that
// starts a group, and in Dot style 1 pt more (the last dot's overhang); none without extra readings
static CGFloat _extra_width(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, int extraCount, const CpuExtraReading* extra)
{
  const int n = _extra_count(extraCount);
  return (n > 0) ? (CPU_RENDER_EXTRA_GAP + _extra_slots(bar, tickWidth, tickTotalWidth, extra, 0, n) +
                    (_group_starts(extra, n-1)*CPU_RENDER_GROUP_GAP) + (bar ? 0.0 : 1.0)) : 0.0;
}

// the clear space before the P-cores' reading when the graph splits: a group gap, after the last E-core dot's 1-pt
// overhang in Dot style
static CGFloat _split_gap(bool bar)
{
  return (bar ? 0.0 : 1.0) + CPU_RENDER_GROUP_GAP;
}

// where block reading index starts: the slots of the readings before it, and the gap after memory when it is after
// memory and any optional reading is shown (with none, the block has no gap). index may be the block's count: the end of
// the readings' slots
static CGFloat _block_x(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, unsigned shown, int index)
{
  CGFloat x = 0.0;
  for (int i=0; i<index; i++)
  {
    x += _block_slot(bar, tickWidth, tickTotalWidth, shown, i);
  }
  const int memory = CpuRenderReadingIndex(shown, CPU_RENDER_KIND_MEMORY);
  return x + (((shown & SHOWN_MASK) != 0 && (index > memory)) ? _split_gap(bar) : 0.0);
}

// where the E-cores' reading starts when the graph splits: after the readings before it (and the gap after memory when
// any optional reading is shown), the 1-pt overhang of the last dot in Dot style, and the readings' gap; their bars start
// a slot later
static CGFloat _efficiency_x(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, unsigned shown)
{
  return _block_x(bar, tickWidth, tickTotalWidth, shown, CpuRenderReadingEfficiency(shown)) + (bar ? 0.0 : 1.0) + CPU_RENDER_READINGS_GAP;
}

int CpuRenderEfficiencyBars(int granularity, natural_t countLogical, const char* kinds)
{
  const natural_t count = CpuSamplerGetCount(granularity);
  // CpuRender averages countLogical / count consecutive CPUs per bar
  if ((kinds == NULL) || (count < 2) || (countLogical < count) || ((countLogical % count) != 0))
  {
    return 0;
  }
  natural_t efficiency = 0;
  while ((efficiency < countLogical) && (kinds[efficiency] == 'E'))
  {
    efficiency++;
  }
  for (natural_t i=efficiency; i<countLogical; i++)
  {
    if (kinds[i] != 'P')
    {
      return 0;
    }
  }
  const natural_t group = countLogical / count;
  if ((efficiency == 0) || (efficiency == countLogical) || ((efficiency % group) != 0))
  {
    return 0;
  }
  return (int)(efficiency / group);
}

CGFloat CpuRenderReadingX(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, unsigned shown, CGFloat imageWidth, int efficiencyBars, natural_t cores, int extraCount, const CpuExtraReading* extra, int index)
{
  const CGFloat slot = _readings_slot(bar, tickWidth, tickTotalWidth);
  const int base = _readings_count(shown);
  const int efficiency = CpuRenderReadingEfficiency(shown);
  if ((index < base) && (efficiencyBars > 0) && (index >= efficiency))
  {
    // the E-cores' reading heads their bars, the P-cores' theirs, after the E-cores' bars and the split's gap
    const CGFloat x = _efficiency_x(bar, tickWidth, tickTotalWidth, shown);
    return (index == efficiency) ? x : (x + slot + (efficiencyBars*CpuRenderCoreSlot(bar, tickWidth, tickTotalWidth, cores)) + _split_gap(bar));
  }
  if (index < base)
  {
    return _block_x(bar, tickWidth, tickTotalWidth, shown, index);
  }
  // an index past the last extra reading gives the last one's x, so that nothing past the array is read
  const int n = _extra_count(extraCount);
  int i = index - base;
  if (i > n-1)
  {
    i = (n > 0) ? n-1 : 0;
  }
  return imageWidth - _extra_width(bar, tickWidth, tickTotalWidth, extraCount, extra) + CPU_RENDER_EXTRA_GAP +
    _extra_slots(bar, tickWidth, tickTotalWidth, extra, 0, i) + (_group_starts(extra, i)*CPU_RENDER_GROUP_GAP);
}

CGFloat CpuRenderExtraWidth(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, int extraCount, const CpuExtraReading* extra)
{
  return _extra_width(bar, tickWidth, tickTotalWidth, extraCount, extra);
}

CGFloat CpuRenderReadingsWidth(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, unsigned shown, int efficiencyBars, int extraCount, const CpuExtraReading* extra)
{
  // as the core graph's own width: a slot per reading (the battery's wider) and the gap after memory, and 1 pt more for
  // dots; the split's gap when the graph splits; then the extra readings' block
  return _block_x(bar, tickWidth, tickTotalWidth, shown, _readings_count(shown)) + (bar ? 0.0 : 1.0) + CPU_RENDER_READINGS_GAP +
    ((efficiencyBars > 0) ? _split_gap(bar) : 0.0) + _extra_width(bar, tickWidth, tickTotalWidth, extraCount, extra);
}

CGFloat CpuRenderCoreSlot(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, natural_t count)
{
  if (!bar || (count <= CPU_RENDER_THIN_FROM))
  {
    return tickTotalWidth;
  }
  // never below a 1-pt bar and the full slot's gap: each core keeps its own bar, apart from the next
  return fmax(1.0 + (tickTotalWidth - tickWidth), fmin(tickTotalWidth, floor((CPU_RENDER_THIN_FROM*tickTotalWidth)/count)));
}

CGFloat CpuRenderCoreWidth(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, natural_t count)
{
  const CGFloat slot = CpuRenderCoreSlot(bar, tickWidth, tickTotalWidth, count);
  return (slot >= tickTotalWidth) ? tickWidth : (slot - (tickTotalWidth - tickWidth));
}

CGFloat CpuRenderCoreX(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, CGFloat start, int efficiencyBars, int count, int index)
{
  const CGFloat shift = ((efficiencyBars > 0) && (index >= efficiencyBars)) ? (_split_gap(bar) + _readings_slot(bar, tickWidth, tickTotalWidth)) : 0.0;
  return start + (index*CpuRenderCoreSlot(bar, tickWidth, tickTotalWidth, (natural_t)count)) + shift;
}

int CpuRenderCoreAtX(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, CGFloat start, int efficiencyBars, int count, CGFloat x)
{
  // the rightmost bar that starts at or left of x holds it, if x is within its slot; the last one's has no right end
  for (int i=count-1; i>=0; i--)
  {
    const CGFloat left = CpuRenderCoreX(bar, tickWidth, tickTotalWidth, start, efficiencyBars, count, i);
    if (x >= left)
    {
      return ((i == count-1) || (x < (left + CpuRenderCoreSlot(bar, tickWidth, tickTotalWidth, (natural_t)count)))) ? i : -1;
    }
  }
  return -1;
}

void CpuRenderGraphSpan(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, CGFloat imageWidth, bool readings, unsigned shown, int efficiencyBars, int extraCount, const CpuExtraReading* extra, CGFloat* start, CGFloat* end)
{
  if (readings && (efficiencyBars > 0))
  {
    *start = _efficiency_x(bar, tickWidth, tickTotalWidth, shown) + _readings_slot(bar, tickWidth, tickTotalWidth);
  }
  else
  {
    *start = readings ? CpuRenderReadingsWidth(bar, tickWidth, tickTotalWidth, shown, 0, 0, NULL) : 0.0;
  }
  *end = imageWidth - _extra_width(bar, tickWidth, tickTotalWidth, extraCount, extra);
}

// where a dashed bar starts: above rows 0 and 1, left clear, so that it is five 2-pt dashes with 1-pt gaps
#define DASHED_BOTTOM 2.0

// a bar's background: 100%, in a light grey, from bottom to the top (bottom 0: the full 16 pt)
static void _render_background(CGContextRef ctx, CGFloat x, CGFloat tickWidth, CGFloat color, bool light, CGFloat bottom)
{
  CGContextSetGrayFillColor(ctx, color, light ? 0.12 : 0.3);
  CGContextFillRect(ctx, CGRectMake(x, bottom, tickWidth, 16-bottom));
}

// one bar (or dot) of the graph at x, at load 0..1, painted as a bar at paint would be; a bar over its background, from
// bottom up
static void _render_group(CGContextRef ctx, CGFloat x, CGFloat load, CGFloat paint, CGFloat color, CGFloat range, bool bar, bool colored, int theme, CGFloat tickWidth, bool light, CGFloat bottom)
{
  if (bar)
  {
    _render_background(ctx, x, tickWidth, color, light, bottom);
  }
  
  CGFloat alpha = (range*paint)+(1.0-range);
  if (!bar)
  {
    alpha = 1.0f;
  }
  
  rgb rgb = {color, color, color}; // dots without colour (the Preferences never ask for them) draw grey
  if (colored)
  {
    rgb = _color(theme, paint);
    CGContextSetRGBFillColor(ctx, rgb.r, rgb.g, rgb.b, alpha);
  }
  else
  {
    CGContextSetGrayFillColor(ctx, color, alpha);
  }
  
  if (bar)
  {
    CGContextFillRect(ctx, CGRectMake(x, bottom, tickWidth, load*(16-bottom)));
  }
  else
  {
    double w = tickWidth + 5.0;
    CGContextSetGrayFillColor(ctx, color, range*1.25);
    CGContextFillEllipseInRect(ctx, CGRectMake(x, ((14.0-w)/2.0), w+1.0, w+1.0));
    CGContextSetRGBFillColor(ctx, rgb.r, rgb.g, rgb.b, alpha);
    CGContextFillEllipseInRect(ctx, CGRectMake(x+1.0, ((14.0-w)/2.0)+1.0, w-1.0, w-1.0));
  }
}

// an extra reading's pace and alert over its bar, as _render_group drew it at x at load and paint: a bar above pace gets
// the part up to pace painted in its ramp's coolest colour, the share its period allows so far, and the part above it,
// the overspend, in its ramp's hottest colour; an alert bar without a pace is painted all in that hottest colour; a bar
// below pace gets the stretch from its top up to pace painted dim in its own colour, the headroom. Bars with colour only
static void _render_pace(CGContextRef ctx, CGFloat x, CGFloat width, CGFloat load, CGFloat paint, double pace, bool alert, CGFloat color, bool bar, bool colored, int theme, bool light, CGFloat bottom)
{
  if (!bar || !colored)
  {
    return;
  }
  const CGFloat height = 16-bottom;
  const CGFloat share = (pace > 0.0) ? fmin(pace, 1.0) : 0.0;
  if ((load > share) && ((share > 0.0) || alert))
  {
    // the whole bar cleared and its background painted again, so that no colour shows through: a clear up to the
    // fill's own top would leave its antialiased edge partly coloured
    CGContextClearRect(ctx, CGRectMake(x, bottom, width, height));
    _render_background(ctx, x, width, color, light, bottom);
    rgb hot = _color(theme, 1.0);
    CGContextSetRGBFillColor(ctx, hot.r, hot.g, hot.b, 1.0);
    CGContextFillRect(ctx, CGRectMake(x, bottom+(share*height), width, (load-share)*height));
    if (share > 0.0)
    {
      rgb cool = _color(theme, 0.0);
      CGContextSetRGBFillColor(ctx, cool.r, cool.g, cool.b, 1.0);
      CGContextFillRect(ctx, CGRectMake(x, bottom, width, share*height));
    }
  }
  else if ((share > 0.0) && (load < share))
  {
    rgb own = _color(theme, paint);
    CGContextSetRGBFillColor(ctx, own.r, own.g, own.b, light ? 0.25 : 0.35);
    CGContextFillRect(ctx, CGRectMake(x, bottom+(load*height), width, (share-load)*height));
  }
}

// an extra reading drawn in its own colour (CpuExtraReading hasColor), at x and the width given: a bar over its background
// in that colour, dim, drawn also when the bar is not read, and the bar's fill opaque; a dot as _render_group draws it
static void _render_colored(CGContextRef ctx, CGFloat x, CGFloat width, CGFloat load, bool read, const CpuExtraReading* reading, CGFloat color, CGFloat range, bool bar, bool light, CGFloat bottom)
{
  if (bar)
  {
    CGContextSetRGBFillColor(ctx, reading->colorRed, reading->colorGreen, reading->colorBlue, light ? 0.25 : 0.35);
    CGContextFillRect(ctx, CGRectMake(x, bottom, width, 16-bottom));
    if (read)
    {
      CGContextSetRGBFillColor(ctx, reading->colorRed, reading->colorGreen, reading->colorBlue, 1.0);
      CGContextFillRect(ctx, CGRectMake(x, bottom, width, load*(16-bottom)));
    }
  }
  else if (read)
  {
    double w = width + 5.0;
    CGContextSetGrayFillColor(ctx, color, range*1.25);
    CGContextFillEllipseInRect(ctx, CGRectMake(x, ((14.0-w)/2.0), w+1.0, w+1.0));
    CGContextSetRGBFillColor(ctx, reading->colorRed, reading->colorGreen, reading->colorBlue, 1.0);
    CGContextFillEllipseInRect(ctx, CGRectMake(x+1.0, ((14.0-w)/2.0)+1.0, w-1.0, w-1.0));
  }
}

// a share bar over its background, in its readings slot at x and width wide, drawn whole from bottom, without the dashes: the
// background, then a fill of share (0..1, above 1 as 1) of the height in fill at alpha; below 0, the background alone
static void _render_share_bar(CGContextRef ctx, CGFloat x, CGFloat width, double share, rgb fill, CGFloat alpha, CGFloat color, bool light, CGFloat bottom)
{
  _render_background(ctx, x, width, color, light, bottom);
  if (share > 0.0)
  {
    CGContextSetRGBFillColor(ctx, fill.r, fill.g, fill.b, alpha);
    CGContextFillRect(ctx, CGRectMake(x, bottom, width, fmin(share, 1.0)*(16-bottom)));
  }
}

// a reading's dot in its readings slot at x: filled in fill (full opacity) when on; else, when ring, a 1-pt ring at the bars'
// background opacity, and when not, nothing
static void _render_dot(CGContextRef ctx, CGFloat x, bool on, bool ring, rgb fill, CGFloat color, CGFloat tickWidth, bool light)
{
  const CGFloat d = tickWidth + 5.0;
  const CGFloat cx = x + ((d + 1.0)/2.0);
  const CGFloat cy = ((14.0 - d)/2.0) + ((d + 1.0)/2.0);
  const CGRect r = CGRectMake(cx - (d/2.0), cy - (d/2.0), d, d);
  if (on)
  {
    CGContextSetRGBFillColor(ctx, fill.r, fill.g, fill.b, 1.0);
    CGContextFillEllipseInRect(ctx, r);
  }
  else if (ring)
  {
    CGContextSetGrayStrokeColor(ctx, color, light ? 0.12 : 0.3);
    CGContextSetLineWidth(ctx, 1.0);
    CGContextStrokeEllipseInRect(ctx, CGRectInset(r, 0.5, 0.5));
  }
}

// the menu bar's text colour: white on a dark menu bar, black on a light one
static rgb _text_color(bool light)
{
  const double t = light ? 0.0 : 1.0;
  rgb c = {t, t, t};
  return c;
}

// the Neural Engine's reading in its readings slot at x; not read (state below 0), nothing. In bar style a wide bar, as
// the readings' are, drawn whole from bottom, without the dashes: on (above 0), filled solid in the menu bar's text
// colour at 0.9 opacity, the brightness of the system's Wi-Fi icon and clock over the dark menu bar (232-233 of 255
// over its 32, measured on screen; the battery's body reads 243); off (0), only the bars' background. In Dot style the readings' dot, where theirs is drawn: on,
// filled in that colour; off, a 1-pt ring at the bars' background opacity
// share, 0..1, when byShare: the share of time busy sets the fill (CpuReadings neuralEngineByShare); else state, ON/OFF
static void _render_neural_engine(CGContextRef ctx, CGFloat x, int state, bool byShare, double share, CGFloat color, bool bar, CGFloat tickWidth, bool light, CGFloat bottom)
{
  if (byShare)
  {
    if (share < 0.0)
    {
      return;
    }
    state = (share >= 0.005) ? 1 : 0;
  }
  if (state < 0)
  {
    return;
  }
  if (bar)
  {
    if (byShare)
    {
      _render_share_bar(ctx, x, 2.0*tickWidth, share, _text_color(light), 0.9, color, light, bottom);
    }
    else if (state > 0)
    {
      CGContextSetGrayFillColor(ctx, light ? 0.0 : 1.0, 0.9);
      CGContextFillRect(ctx, CGRectMake(x, bottom, 2.0*tickWidth, 16-bottom));
    }
    else
    {
      _render_background(ctx, x, 2.0*tickWidth, color, light, bottom);
    }
    return;
  }
  _render_dot(ctx, x, state > 0, true, _text_color(light), color, tickWidth, light);
}

// systemGreen, the colour of a charging battery's fill: sRGB (0.204, 0.780, 0.349) on a light menu bar and (0.188, 0.820,
// 0.345) on a dark one
static rgb _charging_color(bool light)
{
  rgb c = light ? (rgb){0.204, 0.780, 0.349} : (rgb){0.188, 0.820, 0.345};
  return c;
}

// the battery's number, the charge in whole percent, in the system font at 10 pt with monospaced digits, in the menu bar's
// text colour at 0.9 opacity (the Neural Engine's), right-aligned in the CPU_RENDER_BATTERY_TEXT_WIDTH from x and centred
// vertically on the digits' height. The font is made on the first call: the tests never call CpuRenderInit
static void _render_battery_number(CGContextRef ctx, CGFloat x, double charge, bool light)
{
  static CTFontRef font = NULL;
  if (font == NULL)
  {
    CTFontRef base = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 10.0, NULL);
    if (base == NULL)
    {
      return;
    }
    int type = kNumberSpacingType;
    int selector = kMonospacedNumbersSelector;
    CFNumberRef types = CFNumberCreate(NULL, kCFNumberIntType, &type);
    CFNumberRef selectors = CFNumberCreate(NULL, kCFNumberIntType, &selector);
    const void* keys[] = {kCTFontFeatureTypeIdentifierKey, kCTFontFeatureSelectorIdentifierKey};
    const void* values[] = {types, selectors};
    CFDictionaryRef feature = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void* features[] = {feature};
    CFArrayRef list = CFArrayCreate(NULL, features, 1, &kCFTypeArrayCallBacks);
    const void* attributeKeys[] = {kCTFontFeatureSettingsAttribute};
    const void* attributeValues[] = {list};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, attributeKeys, attributeValues, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
    font = CTFontCreateCopyWithAttributes(base, 10.0, NULL, descriptor);
    CFRelease(descriptor);
    CFRelease(attributes);
    CFRelease(list);
    CFRelease(feature);
    CFRelease(selectors);
    CFRelease(types);
    CFRelease(base);
    if (font == NULL)
    {
      return;
    }
  }
  char text[8];
  snprintf(text, sizeof(text), "%d", (int)lround(fmin(fmax(charge, 0.0), 1.0)*100.0));
  CFStringRef string = CFStringCreateWithCString(NULL, text, kCFStringEncodingASCII);
  const void* keys[] = {kCTFontAttributeName, kCTForegroundColorFromContextAttributeName};
  const void* values[] = {font, kCFBooleanTrue};
  CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFAttributedStringRef attributed = CFAttributedStringCreate(NULL, string, attributes);
  CTLineRef line = CTLineCreateWithAttributedString(attributed);
  const double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
  CGContextSetGrayFillColor(ctx, light ? 0.0 : 1.0, 0.9);
  CGContextSetTextMatrix(ctx, CGAffineTransformIdentity); // the context is y-up
  CGContextSetTextPosition(ctx, x + CPU_RENDER_BATTERY_TEXT_WIDTH - width, (16.0 - CTFontGetCapHeight(font))/2.0);
  CTLineDraw(line, ctx);
  CFRelease(line);
  CFRelease(attributed);
  CFRelease(attributes);
  CFRelease(string);
}

// the battery's reading in its slot at x: not read (charge below 0), the bar's background alone in bar style, nothing in Dot
// style, and no number. Else the number, then, CPU_RENDER_BATTERY_TEXT_WIDTH and 1 pt on, a wide bar as the Neural Engine's by-share
// bar is (whole, without the dashes): its fill the charge, in the text colour at 0.9 opacity, or systemGreen at full
// opacity while charging; in Dot style the readings' dot there, filled while the charge is 0.005 or more
static void _render_battery(CGContextRef ctx, CGFloat x, double charge, bool charging, CGFloat color, bool bar, CGFloat tickWidth, bool light, CGFloat bottom)
{
  const CGFloat barX = x + CPU_RENDER_BATTERY_TEXT_WIDTH + 1.0;
  if (!(charge >= 0.0))
  {
    if (bar)
    {
      _render_background(ctx, barX, 2.0*tickWidth, color, light, bottom);
    }
    return;
  }
  const rgb fill = charging ? _charging_color(light) : _text_color(light);
  if (bar)
  {
    _render_share_bar(ctx, barX, 2.0*tickWidth, charge, fill, charging ? 1.0 : 0.9, color, light, bottom);
  }
  else
  {
    _render_dot(ctx, barX, charge >= 0.005, false, fill, color, tickWidth, light);
  }
  _render_battery_number(ctx, x, charge, light);
}

// Wi-Fi's reading in its readings slot at x: a wide bar as the battery's, filled to the signal (fill, 0..1) in the text
// colour at 0.9 opacity; below 0 (off, not connected, not readable) the background alone. In Dot style the readings'
// dot, filled while the fill is 0.005 or more, else a 1-pt ring
static void _render_wifi(CGContextRef ctx, CGFloat x, double fill, CGFloat color, bool bar, CGFloat tickWidth, bool light, CGFloat bottom)
{
  if (bar)
  {
    _render_share_bar(ctx, x, 2.0*tickWidth, fill, _text_color(light), 0.9, color, light, bottom);
  }
  else
  {
    _render_dot(ctx, x, fill >= 0.005, true, _text_color(light), color, tickWidth, light);
  }
}

void CpuRender(CpuSummaryInfo* cpu_info, CGContextRef ctx, bool light, int granularity, bool bar, bool stripped, bool colored, CGFloat tickWidth, CGFloat tickTotalWidth, CGFloat imageWidth, int theme, const CpuReadings* readings)
{
  CGContextClearRect(ctx, CGRectMake(0, 0, imageWidth, 16));
  
  CGFloat color = 0.8;
  if (light)
  {
    color = 0.2;
  }
  
  const CGFloat range = 0.75;
  const CGFloat bottom = stripped ? DASHED_BOTTOM : 0.0;
  
  // the core graph starts after the readings block and its gap when the five readings are drawn, and ends before the
  // extra readings' gap
  const bool block = (readings != NULL) && !readings->extraOnly;
  CGFloat offset = 0.0;
  CGFloat end = imageWidth;
  const int extraCount = (readings != NULL) ? _extra_count(readings->extraCount) : 0;
  const CpuExtraReading* extra = (readings != NULL) ? readings->extra : NULL;
  // the split after the E-cores' bars, only with the five readings drawn
  const int split = (block && (readings->efficiencyBars > 0)) ? readings->efficiencyBars : 0;
  // the optional readings, only with the block's readings drawn
  const unsigned shown = block ? CpuRenderReadingsShown(readings) : 0;
  const bool gpu = (shown & CPU_RENDER_SHOWN_GPU) != 0;
  const int base = _readings_count(shown);
  const natural_t cores = CpuSamplerGetCount(granularity); // at least 1
  CpuRenderGraphSpan(bar, tickWidth, tickTotalWidth, imageWidth, block, shown, split, extraCount, extra, &offset, &end);
  if (readings)
  {
    const int count = base + extraCount;
    // the battery's, Wi-Fi's, disk, memory, (the Neural Engine's, the GPU's,) CPU, the E-cores', the P-cores' from the left,
    // then the extra readings; a value below 0 or NaN is not read and draws only the bar's background, one above 1 draws as
    // 1. The battery's, Wi-Fi's and the Neural Engine's are drawn last, apart (-1 here)
    double block_values[CPU_RENDER_READINGS_MAX];
    for (int i=0; i<base; i++)
    {
      switch (CpuRenderReadingKind(shown, i))
      {
        case CPU_RENDER_KIND_DISK:
          block_values[i] = readings->disk;
          break;
        case CPU_RENDER_KIND_MEMORY:
          block_values[i] = readings->memory;
          break;
        case CPU_RENDER_KIND_GPU:
          block_values[i] = readings->gpu;
          break;
        case CPU_RENDER_KIND_CPU:
          block_values[i] = readings->cpu;
          break;
        case CPU_RENDER_KIND_EFFICIENCY:
          block_values[i] = readings->efficiency;
          break;
        case CPU_RENDER_KIND_PERFORMANCE:
          block_values[i] = readings->performance;
          break;
        default:
          block_values[i] = -1.0;
          break;
      }
    }
    for (int i=block ? 0 : base; i<count; i++)
    {
      const int kind = (i < base) ? CpuRenderReadingKind(shown, i) : -1;
      if ((kind == CPU_RENDER_KIND_BATTERY) || (kind == CPU_RENDER_KIND_WIFI) || (kind == CPU_RENDER_KIND_NEURAL_ENGINE))
      {
        continue;
      }
      const double value = (i < base) ? block_values[i] : (extra ? extra[i-base].value : -1.0);
      const CGFloat width = (i < base) ? (bar ? 2.0*tickWidth : tickWidth) :
        _extra_bar_width(bar, tickWidth, extra, i-base);
      CGFloat x = CpuRenderReadingX(bar, tickWidth, tickTotalWidth, shown, imageWidth, split, cores, extraCount, extra, i);
      if (value >= 0.0)
      {
        const CGFloat load = fmin(value, 1.0);
        const CGFloat paint = (i < base) ? load : _extra_paint(bar, extra, i-base, load);
        if (colored && (i >= base) && extra && extra[i-base].hasColor)
        {
          _render_colored(ctx, x, width, load, true, &extra[i-base], color, range, bar, light, bottom);
          continue;
        }
        const CGFloat spread = (i < base) ? range : _extra_range(bar, colored, extra, i-base, range);
        _render_group(ctx, x, load, paint, color, spread, bar, colored, theme, width, light, bottom);
        if ((i >= base) && extra)
        {
          _render_pace(ctx, x, width, load, paint, extra[i-base].pace, extra[i-base].alert, color, bar, colored, theme, light, bottom);
        }
      }
      else if (bar)
      {
        if (colored && (i >= base) && extra && extra[i-base].hasColor)
        {
          _render_colored(ctx, x, width, 0.0, false, &extra[i-base], color, range, bar, light, bottom);
        }
        else
        {
          _render_background(ctx, x, width, color, light, bottom);
        }
      }
    }
  }
  
  natural_t count = cores;
  natural_t group = cpu_info->countLogical / count;  // 0 when no CPU could be read: nothing to average
  const CGFloat coreWidth = CpuRenderCoreWidth(bar, tickWidth, tickTotalWidth, count);
  for (natural_t i=0; i<count; i++)
  {
    CGFloat load = 0.0;
    if (group > 0)
    {
      for (natural_t j=0; j<group; j++)
      {
        natural_t index = (i*group)+j;
        load += cpu_info->now[index].load;
      }
      load /= (CGFloat)group;
    }
    // the P-cores' bars after the split's gap and the P-cores' reading
    _render_group(ctx, CpuRenderCoreX(bar, tickWidth, tickTotalWidth, offset, split, (int)count, (int)i), load, load, color, range, bar, colored, theme, coreWidth, light, bottom);
  }

  // dashed, the readings' bars as well as the cores': the gaps at 4, 7, 10 and 13 leave five 2-pt dashes above
  // DASHED_BOTTOM
  if (bar && stripped)
  {
    for (natural_t i=4; i<16; i+=3)
    {
      CGContextClearRect(ctx, CGRectMake(0, i, imageWidth, 1));
    }
    // an extra reading's alert: its bar drawn again whole, without the dashes, from the same bottom
    if (readings && extra)
    {
      for (int i=0; i<extraCount; i++)
      {
        const double value = extra[i].value;
        if (extra[i].alert && value >= 0.0)
        {
          CGFloat x = CpuRenderReadingX(bar, tickWidth, tickTotalWidth, shown, imageWidth, split, cores, extraCount, extra, base+i);
          const CGFloat width = _extra_bar_width(bar, tickWidth, extra, i);
          CGContextClearRect(ctx, CGRectMake(x, 0, width, 16));
          const CGFloat load = fmin(value, 1.0);
          const CGFloat paint = _extra_paint(bar, extra, i, load);
          if (colored && extra[i].hasColor)
          {
            _render_colored(ctx, x, width, load, true, &extra[i], color, range, bar, light, bottom);
            continue;
          }
          _render_group(ctx, x, load, paint, color, _extra_range(bar, colored, extra, i, range), bar, colored, theme, width, light, bottom);
          _render_pace(ctx, x, width, load, paint, extra[i].pace, extra[i].alert, color, bar, colored, theme, light, bottom);
        }
      }
    }
  }

  // the extra readings' marks, drawn last so that the dashes do not clear them: a 1-pt line across the bar at the mark's
  // height, white on a dark menu bar and black on a light one
  if (readings && bar && extra)
  {
    for (int i=0; i<extraCount; i++)
    {
      const double value = extra[i].value;
      const double mark = extra[i].mark;
      if (value >= 0.0 && mark > 0.0)
      {
        const double y = fmin(floor(bottom+(fmin(mark, 1.0)*(16.0-bottom))), 15.0); // on the bar's own scale
        CGContextSetGrayFillColor(ctx, light ? 0.0 : 1.0, 1.0);
        CGFloat x = CpuRenderReadingX(bar, tickWidth, tickTotalWidth, shown, imageWidth, split, cores, extraCount, extra, base+i);
        CGContextFillRect(ctx, CGRectMake(x, y, _extra_bar_width(bar, tickWidth, extra, i), 1));
      }
    }
  }

  // the Neural Engine's, the battery's and Wi-Fi's, drawn last so that the dashes do not cut them
  if (gpu)
  {
    _render_neural_engine(ctx, CpuRenderReadingX(bar, tickWidth, tickTotalWidth, shown, imageWidth, split, cores, extraCount, extra, CpuRenderReadingIndex(shown, CPU_RENDER_KIND_NEURAL_ENGINE)),
                          readings->neuralEngine, readings->neuralEngineByShare, readings->neuralEngineBusy, color, bar, tickWidth, light, bottom);
  }
  if ((shown & CPU_RENDER_SHOWN_BATTERY) != 0)
  {
    _render_battery(ctx, CpuRenderReadingX(bar, tickWidth, tickTotalWidth, shown, imageWidth, split, cores, extraCount, extra, CpuRenderReadingIndex(shown, CPU_RENDER_KIND_BATTERY)),
                    readings->battery, readings->batteryCharging, color, bar, tickWidth, light, bottom);
  }
  if ((shown & CPU_RENDER_SHOWN_WIFI) != 0)
  {
    _render_wifi(ctx, CpuRenderReadingX(bar, tickWidth, tickTotalWidth, shown, imageWidth, split, cores, extraCount, extra, CpuRenderReadingIndex(shown, CPU_RENDER_KIND_WIFI)),
                 readings->wifi, color, bar, tickWidth, light, bottom);
  }
}

void CpuRenderDemo(CGContextRef ctx, CGFloat width, CGFloat height, int tint)
{
  CGContextClearRect(ctx, CGRectMake(0, 0, width, height));
  for (natural_t y=0; y<height; y++)
  {
    rgb rgb = _color(tint, (CGFloat)y/height);
    CGContextSetRGBFillColor(ctx, rgb.r, rgb.g, rgb.b, 1);
    CGContextFillRect(ctx, CGRectMake(0, y, width, 1));
  }
}
