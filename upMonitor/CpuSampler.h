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

#ifndef CpuSampler_h
#define CpuSampler_h

#include <mach/mach.h>
#include <mach/boolean.h>
#include <mach/processor_info.h>
#include <mach/mach_init.h>
#include <mach/mach_host.h>
#include <mach/mach_error.h>

__BEGIN_DECLS

struct Ticks
{
  uint64_t  systemTicks;
  uint64_t  userTicks;
  uint64_t  niceTicks;
  uint64_t  idleTicks;
  double    load;
}
typedef Ticks;

struct CpuSummaryInfo
{
  mach_port_t port;
  natural_t   countCores;
  natural_t   countLogical;
  long        frequency;
  Ticks*      last;
  Ticks*      now;
}
typedef CpuSummaryInfo;

natural_t CpuSamplerGetCount(int granularity);

char* CpuSamplerGetCpuType(void);
char* CpuSamplerGetCpuSubtype(void);
long CpuSamplerGetCpuMHz(void);

void CpuSamplerInit(CpuSummaryInfo* cpu_info);
void CpuSamplerUpdate(CpuSummaryInfo* cpu_info);

void CpuSamplerSineDemoInit(CpuSummaryInfo* cpu_info);
void CpuSamplerSineDemoUpdate(CpuSummaryInfo* cpu_info, float speed);

void CpuSamplerFlatDemoInit(CpuSummaryInfo* cpu_info);
void CpuSamplerFlatDemoUpdate(CpuSummaryInfo* cpu_info, float speed);

__END_DECLS

#endif /* CpuSampler_h */
