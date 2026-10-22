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

CGFloat CpuRenderReadingSlot(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, int extraCount, const CpuExtraReading* extra, int index)
{
  if ((index < CPU_RENDER_READINGS_COUNT) || (index - CPU_RENDER_READINGS_COUNT >= _extra_count(extraCount)))
  {
    return _readings_slot(bar, tickWidth, tickTotalWidth);
  }
  return _extra_slot(bar, tickWidth, tickTotalWidth, extra, index - CPU_RENDER_READINGS_COUNT);
}

// the extra readings' block at the right of the image: its gap, the slots of the readings, a group gap for each reading that
// starts a group, and in Dot style 1 pt more (the last dot's overhang); none without extra readings
static CGFloat _extra_width(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, int extraCount, const CpuExtraReading* extra)
{
  const int n = _extra_count(extraCount);
  return (n > 0) ? (CPU_RENDER_EXTRA_GAP + _extra_slots(bar, tickWidth, tickTotalWidth, extra, 0, n) +
                    (_group_starts(extra, n-1)*CPU_RENDER_GROUP_GAP) + (bar ? 0.0 : 1.0)) : 0.0;
}

CGFloat CpuRenderReadingX(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, CGFloat imageWidth, int extraCount, const CpuExtraReading* extra, int index)
{
  const CGFloat slot = _readings_slot(bar, tickWidth, tickTotalWidth);
  if (index < CPU_RENDER_READINGS_COUNT)
  {
    return index*slot;
  }
  // an index past the last extra reading gives the last one's x, so that nothing past the array is read
  const int n = _extra_count(extraCount);
  int i = index - CPU_RENDER_READINGS_COUNT;
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

CGFloat CpuRenderReadingsWidth(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, int extraCount, const CpuExtraReading* extra)
{
  // as the core graph's own width: a slot per reading, and 1 pt more for dots; then the extra readings' block
  return (CPU_RENDER_READINGS_COUNT*_readings_slot(bar, tickWidth, tickTotalWidth)) + (bar ? 0.0 : 1.0) + CPU_RENDER_READINGS_GAP +
    _extra_width(bar, tickWidth, tickTotalWidth, extraCount, extra);
}

void CpuRenderGraphSpan(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, CGFloat imageWidth, bool readings, int extraCount, const CpuExtraReading* extra, CGFloat* start, CGFloat* end)
{
  *start = readings ? CpuRenderReadingsWidth(bar, tickWidth, tickTotalWidth, 0, NULL) : 0.0;
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
// the part up to pace painted in its ramp's coolest colour, the share its period allows so far, and the part above it in
// grey, the marks' colour at half opacity over the bar's background (halfway between it and the mark's line, when the
// bar has one); an alert bar without a pace is painted all in that grey; a bar below pace gets the stretch from its top
// up to pace painted dim in its own colour, the headroom. Bars with colour only
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
    // the marks' colour at half opacity over the background: halfway between the two, whatever the menu bar behind
    CGContextSetGrayFillColor(ctx, light ? 0.0 : 1.0, 0.5);
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
  
  // the core graph starts after the readings block and its gap when the three readings are drawn, and ends before the
  // extra readings' gap
  const bool three = (readings != NULL) && !readings->extraOnly;
  CGFloat offset = 0.0;
  CGFloat end = imageWidth;
  const int extraCount = (readings != NULL) ? _extra_count(readings->extraCount) : 0;
  const CpuExtraReading* extra = (readings != NULL) ? readings->extra : NULL;
  CpuRenderGraphSpan(bar, tickWidth, tickTotalWidth, imageWidth, three, extraCount, extra, &offset, &end);
  if (readings)
  {
    const int count = CPU_RENDER_READINGS_COUNT + extraCount;
    // disk, memory, CPU from the left, then the extra readings; a value below 0 or NaN is not read and draws only the
    // bar's background, one above 1 draws as 1
    const double three_values[CPU_RENDER_READINGS_COUNT] = {readings->disk, readings->memory, readings->cpu};
    for (int i=three ? 0 : CPU_RENDER_READINGS_COUNT; i<count; i++)
    {
      const double value = (i < CPU_RENDER_READINGS_COUNT) ? three_values[i] : (extra ? extra[i-CPU_RENDER_READINGS_COUNT].value : -1.0);
      const CGFloat width = (i < CPU_RENDER_READINGS_COUNT) ? (bar ? 2.0*tickWidth : tickWidth) :
        _extra_bar_width(bar, tickWidth, extra, i-CPU_RENDER_READINGS_COUNT);
      CGFloat x = CpuRenderReadingX(bar, tickWidth, tickTotalWidth, imageWidth, extraCount, extra, i);
      if (value >= 0.0)
      {
        const CGFloat load = fmin(value, 1.0);
        const CGFloat paint = (i < CPU_RENDER_READINGS_COUNT) ? load : _extra_paint(bar, extra, i-CPU_RENDER_READINGS_COUNT, load);
        _render_group(ctx, x, load, paint, color, range, bar, colored, theme, width, light, bottom);
        if ((i >= CPU_RENDER_READINGS_COUNT) && extra)
        {
          _render_pace(ctx, x, width, load, paint, extra[i-CPU_RENDER_READINGS_COUNT].pace, extra[i-CPU_RENDER_READINGS_COUNT].alert, color, bar, colored, theme, light, bottom);
        }
      }
      else if (bar)
      {
        _render_background(ctx, x, width, color, light, bottom);
      }
    }
  }
  
  natural_t count = CpuSamplerGetCount(granularity); // at least 1
  natural_t group = cpu_info->countLogical / count;  // 0 when no CPU could be read: nothing to average
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
    _render_group(ctx, offset+(i*tickTotalWidth), load, load, color, range, bar, colored, theme, tickWidth, light, bottom);
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
          CGFloat x = CpuRenderReadingX(bar, tickWidth, tickTotalWidth, imageWidth, extraCount, extra, CPU_RENDER_READINGS_COUNT+i);
          const CGFloat width = _extra_bar_width(bar, tickWidth, extra, i);
          CGContextClearRect(ctx, CGRectMake(x, 0, width, 16));
          const CGFloat load = fmin(value, 1.0);
          const CGFloat paint = _extra_paint(bar, extra, i, load);
          _render_group(ctx, x, load, paint, color, range, bar, colored, theme, width, light, bottom);
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
        CGFloat x = CpuRenderReadingX(bar, tickWidth, tickTotalWidth, imageWidth, extraCount, extra, CPU_RENDER_READINGS_COUNT+i);
        CGContextFillRect(ctx, CGRectMake(x, y, _extra_bar_width(bar, tickWidth, extra, i), 1));
      }
    }
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
