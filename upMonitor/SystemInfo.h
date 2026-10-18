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

#include <stdbool.h>
#include <stdint.h>
#include <sys/cdefs.h>

__BEGIN_DECLS

// The readings of the panel beside the status menu, all read on this Mac. Main thread only, as the other modules.

// Overall CPU: SystemInfoCpuTick stores the system-wide ticks on every graph tick; SystemInfoCpuBusy gives the busy
// share (0..1) between the newest stored sample and the newest one at least 1 s older, less half a tick (an older
// one where the host's counters had not moved since), or -1 with fewer than two samples or no ticks in them; *span,
// when span is not NULL, gets the window's length in seconds (0 with -1). SystemInfoCpuReset forgets the samples
// (after a pause, so that a window never spans one).
void SystemInfoCpuReset(void);
void SystemInfoCpuTick(void);
double SystemInfoCpuBusy(double* span);

// memory used as Activity Monitor counts it (app memory, wired and compressed) and the physical memory, in bytes
bool SystemInfoMemory(uint64_t* used, uint64_t* total);

// seconds since the last boot, sleep included, past the first minute rounded to the nearest minute as uptime(1)
// does; -1 when the kernel cannot be read
long SystemInfoUptimeSeconds(void);

__END_DECLS

#endif /* SystemInfo_h */
