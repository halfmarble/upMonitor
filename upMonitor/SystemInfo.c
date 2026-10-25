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
#include <stdlib.h>
#include <string.h>
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
  uint32_t ticks[CPU_STATE_MAX];        // the host's
  uint32_t cpuTicks[CPU_STATE_MAX];     // every CPU's, summed
  uint32_t kindTicks[2][CPU_STATE_MAX]; // [0] the E-cores', [1] the P-cores', each summed over its CPUs
  bool     perCpu;              // cpuTicks were read
  bool     kinds;               // kindTicks were read
  double   time;                // s, CLOCK_MONOTONIC_RAW
}
typedef CpuSample;

static CpuSample cpuRing[CPU_RING_SIZE];
static int cpuCount = 0;        // samples stored, at most CPU_RING_SIZE
static int cpuNewest = -1;      // index of the newest sample

static char* cpuKinds = NULL;   // each logical CPU's kind, 'E' or 'P', in host_processor_info's order; NULL: none
static natural_t cpuKindsCount = 0;

void SystemInfoCpuSetKinds(natural_t count, const char* kinds)
{
  free(cpuKinds);
  cpuKinds = NULL;
  cpuKindsCount = 0;
  if ((kinds != NULL) && (count > 0))
  {
    cpuKinds = (char*)malloc(count);
    if (cpuKinds != NULL)
    {
      memcpy(cpuKinds, kinds, count);
      cpuKindsCount = count;
    }
  }
}

// every CPU's ticks, summed, into the sample's cpuTicks (perCpu: false when the CPUs cannot be read), and each kind's,
// summed over its CPUs, into its kindTicks (kinds: false also when there are no kinds or the CPUs' count is not the
// kinds'). The sums wrap in 32 bits as the kernel's counters do, so a difference of two of them is still right across
// a wrap. Each CPU's counters advance about 100 ticks a second, steadily, where the host's stall and catch up (over
// three 1 s windows on an M3, 798-803 summed over its 8 CPUs against the host's 794, 1,121 and 655)
static void CpuEachTicks(CpuSample* sample)
{
  sample->perCpu = false;
  sample->kinds = false;
  natural_t count = 0;
  processor_cpu_load_info_t load = NULL;
  mach_msg_type_number_t size = 0;
  if (host_processor_info(HostPort(), PROCESSOR_CPU_LOAD_INFO, &count, (processor_info_array_t*)&load, &size) != KERN_SUCCESS)
  {
    return;
  }
  bool kinds = (cpuKinds != NULL) && (count == cpuKindsCount);
  memset(sample->cpuTicks, 0, sizeof(sample->cpuTicks));
  memset(sample->kindTicks, 0, sizeof(sample->kindTicks));
  for (natural_t c=0; c<count; c++)
  {
    int kind = (kinds && (cpuKinds[c] == 'E')) ? 0 : 1;
    for (int i=0; i<CPU_STATE_MAX; i++)
    {
      sample->cpuTicks[i] += load[c].cpu_ticks[i];
      sample->kindTicks[kind][i] += load[c].cpu_ticks[i];
    }
  }
  sample->perCpu = true;
  sample->kinds = kinds;
  // size counts integers; vm_deallocate takes bytes
  vm_deallocate(mach_task_self(), (vm_address_t)load, (vm_size_t)size * sizeof(integer_t));
}

// the busy share (0..1) of the ticks between then and now, or -1 with none; differenced in 32 bits, so a wrap is
// harmless
static double CpuTicksBusy(const uint32_t* now, const uint32_t* then)
{
  uint32_t user   = now[CPU_STATE_USER]   - then[CPU_STATE_USER];
  uint32_t system = now[CPU_STATE_SYSTEM] - then[CPU_STATE_SYSTEM];
  uint32_t nice   = now[CPU_STATE_NICE]   - then[CPU_STATE_NICE];
  uint32_t idle   = now[CPU_STATE_IDLE]   - then[CPU_STATE_IDLE];
  double used = (double)user + (double)system + (double)nice;
  double total = used + (double)idle;
  return (total == 0.0) ? -1.0 : used/total;
}

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
  CpuEachTicks(&cpuRing[index]);
  cpuRing[index].time = (double)clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e9;
  cpuNewest = index;
  if (cpuCount < CPU_RING_SIZE)
  {
    cpuCount++;
  }
}

double SystemInfoCpuBusy(double* span, double* efficiency, double* performance)
{
  if (span != NULL)
  {
    *span = 0.0;
  }
  if (efficiency != NULL)
  {
    *efficiency = -1.0;
  }
  if (performance != NULL)
  {
    *performance = -1.0;
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
  // counters have not moved since it (the host's can stall for most of a second, then catch up); none that old: the
  // oldest stored. The CPUs' own summed counters when both samples have them, else the host's
  for (int back=1; back<cpuCount; back++)
  {
    const CpuSample* then = &cpuRing[(cpuNewest - back + CPU_RING_SIZE) % CPU_RING_SIZE];
    if (((now->time - then->time) < (CPU_WINDOW - slack)) && (back < (cpuCount - 1)))
    {
      continue;
    }
    bool perCpu = now->perCpu && then->perCpu;
    double busy = perCpu ? CpuTicksBusy(now->cpuTicks, then->cpuTicks) : CpuTicksBusy(now->ticks, then->ticks);
    if (busy < 0.0)
    {
      continue;
    }
    if (span != NULL)
    {
      *span = now->time - then->time;
    }
    if (now->kinds && then->kinds)
    {
      if (efficiency != NULL)
      {
        *efficiency = CpuTicksBusy(now->kindTicks[0], then->kindTicks[0]);
      }
      if (performance != NULL)
      {
        *performance = CpuTicksBusy(now->kindTicks[1], then->kindTicks[1]);
      }
    }
    return busy;
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
