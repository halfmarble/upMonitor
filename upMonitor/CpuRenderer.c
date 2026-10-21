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

static int _readings_count(int extraCount)
{
  return CPU_RENDER_READINGS_COUNT + ((extraCount < 0) ? 0 : ((extraCount > CPU_RENDER_EXTRA_MAX) ? CPU_RENDER_EXTRA_MAX : extraCount));
}

// the extra readings' block at the right of the image: its gap, a slot per reading, and 1 pt more for dots; none
// without extra readings
static CGFloat _extra_width(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, int extraCount)
{
  const int extra = _readings_count(extraCount) - CPU_RENDER_READINGS_COUNT;
  return (extra > 0) ? (CPU_RENDER_EXTRA_GAP + (extra*_readings_slot(bar, tickWidth, tickTotalWidth)) + (bar ? 0.0 : 1.0)) : 0.0;
}

CGFloat CpuRenderReadingX(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, CGFloat imageWidth, int extraCount, int index)
{
  const CGFloat slot = _readings_slot(bar, tickWidth, tickTotalWidth);
  if (index < CPU_RENDER_READINGS_COUNT)
  {
    return index*slot;
  }
  return imageWidth - _extra_width(bar, tickWidth, tickTotalWidth, extraCount) + CPU_RENDER_EXTRA_GAP +
    ((index - CPU_RENDER_READINGS_COUNT)*slot);
}

CGFloat CpuRenderExtraWidth(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, int extraCount)
{
  return _extra_width(bar, tickWidth, tickTotalWidth, extraCount);
}

CGFloat CpuRenderReadingsWidth(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, int extraCount)
{
  // as the core graph's own width: a slot per reading, and 1 pt more for dots; then the extra readings' block
  return (CPU_RENDER_READINGS_COUNT*_readings_slot(bar, tickWidth, tickTotalWidth)) + (bar ? 0.0 : 1.0) + CPU_RENDER_READINGS_GAP +
    _extra_width(bar, tickWidth, tickTotalWidth, extraCount);
}

void CpuRenderGraphSpan(bool bar, CGFloat tickWidth, CGFloat tickTotalWidth, CGFloat imageWidth, bool readings, int extraCount, CGFloat* start, CGFloat* end)
{
  *start = readings ? CpuRenderReadingsWidth(bar, tickWidth, tickTotalWidth, 0) : 0.0;
  *end = imageWidth - _extra_width(bar, tickWidth, tickTotalWidth, extraCount);
}

// where a dashed bar starts: above rows 0 and 1, left clear, so that it is five 2-pt dashes with 1-pt gaps
#define DASHED_BOTTOM 2.0

// a bar's background: 100%, in a light grey, from bottom to the top (bottom 0: the full 16 pt)
static void _render_background(CGContextRef ctx, CGFloat x, CGFloat tickWidth, CGFloat color, bool light, CGFloat bottom)
{
  CGContextSetGrayFillColor(ctx, color, light ? 0.12 : 0.3);
  CGContextFillRect(ctx, CGRectMake(x, bottom, tickWidth, 16-bottom));
}

// one bar (or dot) of the graph at x, at load 0..1; a bar over its background, from bottom up
static void _render_group(CGContextRef ctx, CGFloat x, CGFloat load, CGFloat color, CGFloat range, bool bar, bool colored, int theme, CGFloat tickWidth, bool light, CGFloat bottom)
{
  if (bar)
  {
    _render_background(ctx, x, tickWidth, color, light, bottom);
  }
  
  CGFloat alpha = (range*load)+(1.0-range);
  if (!bar)
  {
    alpha = 1.0f;
  }
  
  rgb rgb = {color, color, color}; // dots without colour (the Preferences never ask for them) draw grey
  if (colored)
  {
    rgb = _color(theme, load);
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
  CpuRenderGraphSpan(bar, tickWidth, tickTotalWidth, imageWidth, three, (readings != NULL) ? readings->extraCount : 0, &offset, &end);
  if (readings)
  {
    const int count = _readings_count(readings->extraCount);
    // disk, memory, CPU from the left, then the extra readings; a value below 0 or NaN is not read and draws only the
    // bar's background, one above 1 draws as 1
    double values[CPU_RENDER_READINGS_COUNT+CPU_RENDER_EXTRA_MAX] = {readings->disk, readings->memory, readings->cpu};
    for (int i=CPU_RENDER_READINGS_COUNT; i<count; i++)
    {
      values[i] = readings->extra[i-CPU_RENDER_READINGS_COUNT];
    }
    const CGFloat width = bar ? 2.0*tickWidth : tickWidth;
    for (int i=three ? 0 : CPU_RENDER_READINGS_COUNT; i<count; i++)
    {
      CGFloat x = CpuRenderReadingX(bar, tickWidth, tickTotalWidth, imageWidth, readings->extraCount, i);
      if (values[i] >= 0.0)
      {
        _render_group(ctx, x, fmin(values[i], 1.0), color, range, bar, colored, theme, width, light, bottom);
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
    _render_group(ctx, offset+(i*tickTotalWidth), load, color, range, bar, colored, theme, tickWidth, light, bottom);
  }

  // dashed, the readings' bars as well as the cores': the gaps at 4, 7, 10 and 13 leave five 2-pt dashes above
  // DASHED_BOTTOM
  if (bar && stripped)
  {
    for (natural_t i=4; i<16; i+=3)
    {
      CGContextClearRect(ctx, CGRectMake(0, i, imageWidth, 1));
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
