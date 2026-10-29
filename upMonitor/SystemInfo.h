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

#ifndef SystemInfo_h
#define SystemInfo_h

#include <mach/mach_types.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/cdefs.h>

__BEGIN_DECLS

// The readings of the panel beside the status menu, all read on this Mac. Main thread only, as the other modules.

// Overall CPU: SystemInfoCpuTick stores the system-wide ticks on every graph tick, every CPU's summed and the host's;
// SystemInfoCpuBusy gives the busy share (0..1), from the CPUs' summed ticks when both samples have them, else from
// the host's, between the newest stored sample and the newest one at least 1 s older, less half a tick (an older one
// where the counters had not moved since), or -1 with fewer than two samples or no ticks in them; *span,
// when span is not NULL, gets the window's length in seconds (0 with -1). SystemInfoCpuReset forgets the samples
// (after a pause, so that a window never spans one).
// By kind: once SystemInfoCpuSetKinds has each logical CPU's kind, 'E' or 'P' (CpuSamplerGetKinds), every tick also
// stores each kind's ticks, summed over its CPUs, and *efficiency and *performance, when not NULL, get each kind's busy
// share over the same window, or -1 when it cannot be given (no kinds set, a sample without them, no CPU of that
// kind, no ticks in it). SystemInfoCpuSetKinds copies the kinds; NULL forgets them.
void SystemInfoCpuSetKinds(natural_t count, const char* kinds);
void SystemInfoCpuReset(void);
void SystemInfoCpuTick(void);
double SystemInfoCpuBusy(double* span, double* efficiency, double* performance);

// memory used as Activity Monitor counts it (app memory, wired and compressed) and the physical memory, in bytes
bool SystemInfoMemory(uint64_t* used, uint64_t* total);

// swap in use, vm.swapusage's used, in bytes
bool SystemInfoSwap(uint64_t* used);

// seconds since the last boot, sleep included, past the first minute rounded to the nearest minute as uptime(1)
// does; -1 when the kernel cannot be read
long SystemInfoUptimeSeconds(void);

// the GPU's busy share, 0..1: IOAccelerator's "Device Utilization %" over 100, the highest among the services that carry
// it (one per GPU); -1 when it cannot be read. The services are looked up on the first call and kept; after a lookup
// that finds none, the next is tried at most once a minute
double SystemInfoGpuBusy(void);

// the Neural Engine's power: 1 when the H11ANEIn service's IOPowerManagement CurrentPowerState is above 0, 0 when it is
// 0, -1 when there is no such service or the state cannot be read. Its power, not its work: it turns on with work and
// off seconds after it. Looked up as SystemInfoGpuBusy's services are
int SystemInfoNeuralEngine(void);

__END_DECLS

#endif /* SystemInfo_h */
