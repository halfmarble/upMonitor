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

#include "CpuSampler.h"

#include <stdlib.h>
#include <math.h>
#include <sys/sysctl.h>

static char *_cpuType = NULL;
static char *_cpuSubtype = NULL;
static long _frequency = 0;

static host_basic_info_t _CpuSamplerGetCounts()
{
  static boolean_t initialized = FALSE;
  static host_basic_info_data_t basic_info;
  mach_msg_type_number_t msg_count = HOST_BASIC_INFO_COUNT;
  if (!initialized)
  {
    initialized = TRUE;
    
    kern_return_t error = host_info(mach_host_self(), HOST_BASIC_INFO, (host_info_t)&basic_info, &msg_count);
    if (error != KERN_SUCCESS)
    {
      mach_error("host_info error:", error);
      memset(&basic_info, 0x0, sizeof(host_basic_info_data_t));
    }
    else
    {
//      struct host_basic_info {
//        integer_t               max_cpus;               /* max number of CPUs possible */
//        integer_t               avail_cpus;             /* number of CPUs now available */
//        natural_t               memory_size;            /* size of memory in bytes, capped at 2 GB */
//        cpu_type_t              cpu_type;               /* cpu type */
//        cpu_subtype_t           cpu_subtype;            /* cpu subtype */
//        cpu_threadtype_t        cpu_threadtype;         /* cpu threadtype */
//        integer_t               physical_cpu;           /* number of physical CPUs now available */
//        integer_t               physical_cpu_max;       /* max number of physical CPUs possible */
//        integer_t               logical_cpu;            /* number of logical cpu now available */
//        integer_t               logical_cpu_max;        /* max number of physical CPUs possible */
//        uint64_t                max_mem;                /* actual size of physical memory */
//      };
//    max_cpus: 8
//    avail_cpus: 8
//    physical_cpu: 4
//    physical_cpu_max: 4
//    logical_cpu: 8
//    logical_cpu_max: 8
//
//      cpu_type: x86_64h
//      cpu_subtype: Intel x86-64h Haswell
      slot_name(basic_info.cpu_type, basic_info.cpu_subtype, &_cpuType, &_cpuSubtype);

      size_t size = sizeof(_frequency);
      int mib[] = { CTL_HW, HW_CPU_FREQ };
      if (sysctl(mib, 2, &_frequency, &size, NULL, 0) == 0)
      {
        _frequency /= 1000000;
      }
    }
  }
  return &basic_info;
}

static natural_t _CpuSamplerGet(mach_port_t port, Ticks* ticks)
{
  natural_t cpu_count = 0;
  processor_cpu_load_info_t cpu_load;
  mach_msg_type_number_t msg_count = PROCESSOR_CPU_LOAD_INFO_COUNT;
  kern_return_t error = host_processor_info(port, PROCESSOR_CPU_LOAD_INFO, &cpu_count, (processor_info_array_t *)&cpu_load, &msg_count);
  if (error != KERN_SUCCESS)
  {
    mach_error("host_processor_info error:", error);
    memset(&cpu_load, 0x0, sizeof(processor_cpu_load_info_t));
  }
  else if (ticks != NULL)
  {
    for (natural_t i=0; i<cpu_count; i++)
    {
      ticks[i].systemTicks = cpu_load[i].cpu_ticks[CPU_STATE_SYSTEM];
      ticks[i].userTicks   = cpu_load[i].cpu_ticks[CPU_STATE_USER];
      ticks[i].niceTicks   = cpu_load[i].cpu_ticks[CPU_STATE_NICE];
      ticks[i].idleTicks   = cpu_load[i].cpu_ticks[CPU_STATE_IDLE];
    }
  }
  error = vm_deallocate(mach_task_self(), (vm_address_t)cpu_load, msg_count);
  if (error != KERN_SUCCESS)
  {
    mach_error("vm_deallocate error:", error);
  }

  return cpu_count;
}

natural_t CpuSamplerGetCount(int granularity)
{
  host_basic_info_t info = _CpuSamplerGetCounts();
  switch(granularity)
  {
    case 1: return info->physical_cpu;
    case 2: return info->logical_cpu;
    default: return 1;
  }
}

char* CpuSamplerGetCpuType()
{
  _CpuSamplerGetCounts();
  return _cpuType;
}

char* CpuSamplerGetCpuSubtype()
{
  _CpuSamplerGetCounts();
  return _cpuSubtype;
}

long CpuSamplerGetCpuMHz()
{
  _CpuSamplerGetCounts();
  return _frequency;
}

void CpuSamplerInit(CpuSummaryInfo* cpu_info)
{
  memset(cpu_info, 0x00, sizeof(CpuSummaryInfo));
  
  cpu_info->port = mach_host_self();
  cpu_info->countLogical = _CpuSamplerGet(cpu_info->port, NULL);
  host_basic_info_t info = _CpuSamplerGetCounts();
  cpu_info->countCores = info->physical_cpu;

  size_t size = cpu_info->countLogical*sizeof(Ticks);
  cpu_info->last = (Ticks*)malloc(size);
  memset(cpu_info->last, 0x00, size);
  cpu_info->now = (Ticks*)malloc(size);
  memset(cpu_info->now, 0x00, size);
  
  _CpuSamplerGet(cpu_info->port, cpu_info->last);
  CpuSamplerUpdate(cpu_info);
}

void CpuSamplerUpdate(CpuSummaryInfo* cpu_info)
{
  _CpuSamplerGet(cpu_info->port, cpu_info->now);
  
  for (natural_t i=0; i<cpu_info->countLogical; i++)
  {
    uint64_t systemTicks = cpu_info->now[i].systemTicks - cpu_info->last[i].systemTicks;
    uint64_t userTicks   = cpu_info->now[i].userTicks   - cpu_info->last[i].userTicks;
    uint64_t niceTicks   = cpu_info->now[i].niceTicks   - cpu_info->last[i].niceTicks;
    uint64_t idleTicks   = cpu_info->now[i].idleTicks   - cpu_info->last[i].idleTicks;
    {
      double used = systemTicks + userTicks + niceTicks;
      double total = used + idleTicks;
      if (total == 0.0)
      {
        total = 1.0;
      }
      cpu_info->now[i].load = used/total;
    }
    cpu_info->last[i] = cpu_info->now[i];
  }
}

void CpuSamplerSineDemoInit(CpuSummaryInfo* cpu_info)
{
  cpu_info->port = mach_host_self();
  cpu_info->countLogical = _CpuSamplerGet(cpu_info->port, NULL);
  host_basic_info_t info = _CpuSamplerGetCounts();
  cpu_info->countCores = info->physical_cpu;

  size_t size = cpu_info->countLogical*sizeof(Ticks);
  cpu_info->now = (Ticks*)malloc(size);
  memset(cpu_info->now, 0x00, size);
  
  CpuSamplerSineDemoUpdate(cpu_info, 1.0);
}

void CpuSamplerSineDemoUpdate(CpuSummaryInfo* cpu_info, float speed)
{
  static double counter = 0.0;
  for (natural_t i=0; i<cpu_info->countLogical; i++)
  {
    cpu_info->now[i].load = (sin(3.5*counter)/2.0) + 0.5;
    counter += (0.025*speed);
  }
}

void CpuSamplerFlatDemoInit(CpuSummaryInfo* cpu_info)
{
  cpu_info->port = mach_host_self();
  cpu_info->countLogical = _CpuSamplerGet(cpu_info->port, NULL);
  host_basic_info_t info = _CpuSamplerGetCounts();
  cpu_info->countCores = info->physical_cpu;

  size_t size = cpu_info->countLogical*sizeof(Ticks);
  cpu_info->now = (Ticks*)malloc(size);
  memset(cpu_info->now, 0x00, size);
  
  CpuSamplerSineDemoUpdate(cpu_info, 1.0);
}

void CpuSamplerFlatDemoUpdate(CpuSummaryInfo* cpu_info, float speed)
{
  static double load = 0.0;
  for (natural_t i=0; i<cpu_info->countLogical; i++)
  {
    cpu_info->now[i].load = load;
  }
  load += (0.04*speed);
  if (load > 1.0)
  {
    load = 0.0;
  }
}
