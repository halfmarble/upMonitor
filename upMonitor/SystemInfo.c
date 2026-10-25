// The MIT License (MIT)

// Copyright 2026 Halfmarble LLC

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

#include "SystemInfo.h"

#include <mach/mach.h>
#include <sys/sysctl.h>
#include <time.h>

// taken once and kept, as CpuSampler.c keeps its port: each mach_host_self() adds a reference to the port
static mach_port_t HostPort(void)
{
  static mach_port_t host = MACH_PORT_NULL;
  if (host == MACH_PORT_NULL)
  {
    host = mach_host_self();
  }
  return host;
}

#pragma mark - CPU

#define CPU_RING_SIZE   (64)    // 6.3 s at the fastest refresh (0.1 s), enough for a 1 s window at every setting
#define CPU_WINDOW      (1.0)   // s

struct CpuSample
{
  uint32_t ticks[CPU_STATE_MAX];
  double   time;                // s, CLOCK_MONOTONIC_RAW
}
typedef CpuSample;

static CpuSample cpuRing[CPU_RING_SIZE];
static int cpuCount = 0;        // samples stored, at most CPU_RING_SIZE
static int cpuNewest = -1;      // index of the newest sample

void SystemInfoCpuReset(void)
{
  cpuCount = 0;
  cpuNewest = -1;
}

void SystemInfoCpuTick(void)
{
  host_cpu_load_info_data_t load;
  mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
  if (host_statistics(HostPort(), HOST_CPU_LOAD_INFO, (host_info_t)&load, &count) != KERN_SUCCESS)
  {
    // no reading: the ring keeps what it has
    return;
  }
  int index = (cpuNewest + 1) % CPU_RING_SIZE;
  for (int i=0; i<CPU_STATE_MAX; i++)
  {
    cpuRing[index].ticks[i] = load.cpu_ticks[i];
  }
  cpuRing[index].time = (double)clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e9;
  cpuNewest = index;
  if (cpuCount < CPU_RING_SIZE)
  {
    cpuCount++;
  }
}

double SystemInfoCpuBusy(double* span)
{
  if (span != NULL)
  {
    *span = 0.0;
  }
  if (cpuCount < 2)
  {
    return -1.0;
  }
  const CpuSample* now = &cpuRing[cpuNewest];
  // half a tick, from the newest two samples: a tick firing a little early must not push the window a whole tick past
  // CPU_WINDOW, as the readings' own threshold allows the same
  const double slack = 0.5 * (now->time - cpuRing[(cpuNewest - 1 + CPU_RING_SIZE) % CPU_RING_SIZE].time);
  // walk back from the newest to the first sample at least CPU_WINDOW older, less that half tick, and on while the
  // host's counters have not moved since it (they can stall for most of a second, then catch up); none that old: the
  // oldest stored
  for (int back=1; back<cpuCount; back++)
  {
    const CpuSample* then = &cpuRing[(cpuNewest - back + CPU_RING_SIZE) % CPU_RING_SIZE];
    if (((now->time - then->time) < (CPU_WINDOW - slack)) && (back < (cpuCount - 1)))
    {
      continue;
    }
    // the counters are differenced in 32 bits, so a wrap is harmless
    uint32_t user   = now->ticks[CPU_STATE_USER]   - then->ticks[CPU_STATE_USER];
    uint32_t system = now->ticks[CPU_STATE_SYSTEM] - then->ticks[CPU_STATE_SYSTEM];
    uint32_t nice   = now->ticks[CPU_STATE_NICE]   - then->ticks[CPU_STATE_NICE];
    uint32_t idle   = now->ticks[CPU_STATE_IDLE]   - then->ticks[CPU_STATE_IDLE];
    double used = (double)user + (double)system + (double)nice;
    double total = used + (double)idle;
    if (total == 0.0)
    {
      continue;
    }
    if (span != NULL)
    {
      *span = now->time - then->time;
    }
    return used/total;
  }
  return -1.0;
}

#pragma mark - Memory

bool SystemInfoMemory(uint64_t* used, uint64_t* total)
{
  uint64_t memsize = 0;
  size_t size = sizeof(memsize);
  if ((sysctlbyname("hw.memsize", &memsize, &size, NULL, 0) != 0) || (memsize == 0))
  {
    return false;
  }

  vm_statistics64_data_t vm;
  mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
  if (host_statistics64(HostPort(), HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS)
  {
    return false;
  }
  // app memory (anonymous pages that are not purgeable), wired and compressed
  uint64_t internal = vm.internal_page_count;
  uint64_t purgeable = vm.purgeable_count;
  uint64_t app = (internal > purgeable) ? (internal - purgeable) : 0;
  uint64_t pages = app + vm.wire_count + vm.compressor_page_count;

  *used = pages * (uint64_t)vm_kernel_page_size;
  *total = memsize;
  return true;
}

bool SystemInfoSwap(uint64_t* used)
{
  struct xsw_usage swap;
  size_t size = sizeof(swap);
  if ((sysctlbyname("vm.swapusage", &swap, &size, NULL, 0) != 0) || (size != sizeof(swap)))
  {
    return false;
  }
  *used = swap.xsu_used;
  return true;
}

#pragma mark - Uptime

long SystemInfoUptimeSeconds(void)
{
  struct timeval boot = {0, 0};
  size_t size = sizeof(boot);
  int mib[2] = {CTL_KERN, KERN_BOOTTIME};
  if ((sysctl(mib, 2, &boot, &size, NULL, 0) != 0) || (size != sizeof(boot)) || (boot.tv_sec <= 0))
  {
    return -1;
  }
  long seconds = (long)(time(NULL) - boot.tv_sec);
  if (seconds < 0)
  {
    return -1;
  }
  if (seconds > 60)
  {
    seconds += 30;
  }
  return seconds;
}
