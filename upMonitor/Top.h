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

#ifndef Top_h
#define Top_h

#include <sys/types.h>

__BEGIN_DECLS

#define TOP_MAX_SAMPLE_NAME_SIZE (128)
#define TOP_MAX_INFO_NAME_SIZE (4096)

typedef struct TopProcessSample TopProcessSample_t;
struct TopProcessSample
{
  uid_t    uid;
  pid_t    pid;
  pid_t    ppid;
  int32_t  tprio;
  uint32_t status;
  uint32_t flags;
  char     name[TOP_MAX_SAMPLE_NAME_SIZE+1];
  double   cpu;          // % of one core since the previous read, 0 when there is no baseline
  int      cpu_known;    // 0 = unknown, 1 = measured by upMonitor (the user's own processes),
                         // 2 = taken from /usr/bin/top (other users' processes, while the menu is open)

  uint32_t sequence;

  uint64_t start_us;     // process start time, a change means the pid was reused
  uint64_t total_timens; // CPU time at the last read
  uint64_t last_timens;  // wall time of the last read, 0 = no baseline yet
};

typedef struct TopProcessInfo TopProcessInfo_t;
struct TopProcessInfo
{  
  char* name;
  char* command;

  char* args_info;
  int args_count;
  int args_length;

  char* envs_info;
  int envs_count;
  int envs_length;
};

int TopInit(void);
int TopSample(void);
const TopProcessSample_t* TopIterate(void);
const char* TopGetUsername(uid_t a_uid);
TopProcessInfo_t* TopGetArgs(pid_t pid);
TopProcessSample_t* TopGetSample(pid_t pid);
// CPU values for other users' processes, parsed from /usr/bin/top; count 0 clears them. Main thread only.
void TopSetOthersCpu(const pid_t* pids, const double* cpus, int count);

__END_DECLS

#endif /* Top_h */
