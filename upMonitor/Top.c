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

#include <stdlib.h>
#include <limits.h>
#include <libproc.h>
#include <pwd.h>

#include <sys/param.h>
#include <sys/sysctl.h>
#include <sys/time.h>

#include <mach/mach.h>
#include <mach/task.h>
#include <mach/mach_host.h>
#include <mach/mach_port.h>
#include <mach/mach_types.h>
#include <mach/mach_time.h>

#include <CoreFoundation/CoreFoundation.h>

#include "Top.h"
#include "rb.h"

#define TIME_VALUE_TO_TIMEVAL(a, r) do { \
  (r)->tv_sec = (a)->seconds;             \
  (r)->tv_usec = (a)->microseconds;       \
} while (0)

#define TIME_VALUE_TO_NS(a) \
    (((uint64_t)((a)->seconds) * NSEC_PER_SEC) + \
    ((uint64_t)((a)->microseconds) * NSEC_PER_USEC))

#define NS_TO_TIMEVAL(NS) \
    (struct timeval){ .tv_sec = (NS) / NSEC_PER_SEC, \
    .tv_usec = ((NS) % NSEC_PER_SEC) / NSEC_PER_USEC, }

typedef struct _TopProcessInfo _TopProcessInfo_t;
struct _TopProcessInfo
{
  TopProcessSample_t sample;
  rb_node(_TopProcessInfo_t) node_new;
  rb_node(_TopProcessInfo_t) node_sorted;
};

static TopProcessInfo_t _top_process_info;

static uint32_t _top_sequence;
static uint32_t _top_process_count;
static mach_port_t _top_port;
static uint64_t _timens;
static uint64_t _top_wall_us;
static uint64_t _top_prev_timens;
static uint64_t _top_prev_wall_us;
static mach_timebase_info_data_t _top_timebase;

/* Buffer that is large enough to hold the entire argument area of a process. */
static char *_top_arg_buffer;
static int _top_arg_max;

/* Cache of uid->username translations. */
static CFMutableDictionaryRef _top_username_hash_table;
//static CFMutableDictionaryRef _top_hash_table;

/* Other users' CPU values from /usr/bin/top, sorted by pid (TopSetOthersCpu). */
static pid_t* _top_others_pids;
static double* _top_others_cpus;
static int _top_others_count;

static rb_tree(_TopProcessInfo_t) _top_pid_tree;
static rb_tree(_TopProcessInfo_t) _top_sorted_tree;
static boolean_t _top_is_sorted;
static _TopProcessInfo_t* _top_iterator;

static void simpleFree(CFAllocatorRef allocator, const void *value)
{
  free((void *)value);
}

static const void* stringRetain(CFAllocatorRef allocator, const void *value)
{
  return strdup(value);
}

static Boolean stringEqual(const void *value1, const void *value2)
{
  return strcmp(value1, value2) == 0;
}

static int _top_compare_pid_func(const _TopProcessInfo_t *a, const _TopProcessInfo_t *b)
{
  if (a->sample.pid < b->sample.pid) return -1;
  if (a->sample.pid > b->sample.pid) return 1;
  return 0;
}

static int _top_compare_cpu_func(const _TopProcessInfo_t *a, const _TopProcessInfo_t *b)
{
  if (a->sample.cpu > b->sample.cpu) return -1;
  if (a->sample.cpu < b->sample.cpu) return 1;
  return 0;
}

static void _top_insert(_TopProcessInfo_t *pinfo)
{
  rb_node_new(&_top_pid_tree, pinfo, node_new);
  rb_insert(&_top_pid_tree, pinfo, _top_compare_pid_func, _TopProcessInfo_t, node_new);
}

static void _top_remove(_TopProcessInfo_t *pinfo)
{
  rb_remove(&_top_pid_tree, pinfo, _TopProcessInfo_t, node_new);
}

static _TopProcessInfo_t* _top_search(pid_t pid)
{
  _TopProcessInfo_t* retval, key;

  key.sample.pid = pid;
  rb_search(&_top_pid_tree, &key, _top_compare_pid_func, node_new, retval);
  if (retval == rb_tree_nil(&_top_pid_tree))
  {
    retval = NULL;
  }
  return retval;
}

TopProcessSample_t* TopGetSample(pid_t pid)
{
  struct _TopProcessInfo *info = _top_search(pid);
  if (info != NULL)
  {
    return &info->sample;
  }
  else
  {
    return NULL;
  }
}

static int _top_compare_pid_key(const void *a, const void *b)
{
  pid_t pa = *(const pid_t *)a;
  pid_t pb = *(const pid_t *)b;
  return (pa < pb) ? -1 : ((pa > pb) ? 1 : 0);
}

// sets cpu and cpu_known of another user's process from the table /usr/bin/top filled
static void _top_apply_others_cpu(TopProcessSample_t* sample)
{
  pid_t* found = NULL;
  if (_top_others_count > 0)
  {
    found = bsearch(&sample->pid, _top_others_pids, _top_others_count, sizeof(pid_t), _top_compare_pid_key);
  }
  if (found != NULL)
  {
    sample->cpu = _top_others_cpus[found - _top_others_pids];
    sample->cpu_known = 2;
  }
  else
  {
    sample->cpu = 0.0;
    sample->cpu_known = 0;
  }
}

static void _top_destroy(_TopProcessInfo_t *pinfo)
{
  _top_remove(pinfo);
  free(pinfo);
}

static int __attribute__((noinline)) _top_kinfo_for_pid(struct kinfo_proc* kinfo, pid_t pid)
{
  size_t miblen = 4;
  int mib[miblen];
  mib[0] = CTL_KERN;
  mib[1] = KERN_PROC;
  mib[2] = KERN_PROC_PID;
  mib[3] = pid;
  size_t len = sizeof(struct kinfo_proc);
  // for a pid that has already exited, sysctl succeeds but returns no data (len 0)
  if ((sysctl(mib, (u_int)miblen, kinfo, &len, NULL, 0) != 0) || (len != sizeof(struct kinfo_proc)))
  {
    return (-1);
  }
  return (0);
}

// Identity (name, uid, ppid, status) comes from proc_pidinfo(PROC_PIDT_SHORTBSDINFO), which works for
// every process. CPU time and start time come from proc_pidinfo(PROC_PIDTASKALLINFO), which works only
// for the user's own processes: other users' processes (root daemons, WindowServer...) take their CPU
// from /usr/bin/top while the menu is open (cpu_known 2), and are unknown (0) otherwise. Both are much
// cheaper than sysctl(KERN_PROC_PID).
static int __attribute__((noinline)) _top_update_for_pid(pid_t pid)
{
  struct proc_bsdshortinfo bsdinfo;
  if (proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsdinfo, PROC_PIDT_SHORTBSDINFO_SIZE) != PROC_PIDT_SHORTBSDINFO_SIZE)
  {
    return (-2);
  }
  
  if (bsdinfo.pbsi_status == SZOMB)
  {
    return (-3);
  }
  
  _TopProcessInfo_t* pinfo = _top_search((pid_t)pid);
  if (pinfo == NULL)
  {
    pinfo = (_TopProcessInfo_t *)calloc(1, sizeof(_TopProcessInfo_t));
    if (pinfo == NULL)
    {
      return (-1);
    }
    pinfo->sample.pid = (pid_t)pid;
    _top_insert(pinfo);
  }
  TopProcessSample_t* sample = &pinfo->sample;
  
  sample->sequence = _top_sequence;
  sample->uid = bsdinfo.pbsi_uid;
  sample->ppid = bsdinfo.pbsi_ppid;
  sample->status = bsdinfo.pbsi_status;
  sample->flags = bsdinfo.pbsi_flags;
  sample->tprio = 0;
  snprintf(sample->name, sizeof(sample->name), "%.*s", (int)sizeof(bsdinfo.pbsi_comm), bsdinfo.pbsi_comm);
  
  struct proc_taskallinfo pidinfo;
  if (proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &pidinfo, PROC_PIDTASKALLINFO_SIZE) != PROC_PIDTASKALLINFO_SIZE)
  {
    // another user's process: macOS gives an unprivileged app no CPU time for it, /usr/bin/top may
    _top_apply_others_cpu(sample);
    sample->start_us = 0;
    sample->last_timens = 0;
    return (0);
  }
  
  uint64_t start_us = (pidinfo.pbsd.pbi_start_tvsec * USEC_PER_SEC) + pidinfo.pbsd.pbi_start_tvusec;
  if (sample->start_us != start_us)
  {
    // first sight, or the pid now belongs to a new process
    sample->start_us = start_us;
    if ((_top_prev_timens != 0) && (start_us >= _top_prev_wall_us))
    {
      // started after the previous sample: all of its CPU time was used since then
      sample->total_timens = 0;
      sample->last_timens = _top_prev_timens;
    }
    else
    {
      // older than the previous sample (or this is the first sample): no baseline yet
      sample->last_timens = 0;
    }
  }
  
  if (pidinfo.pbsd.pbi_name[0] != '\0')
  {
    snprintf(sample->name, sizeof(sample->name), "%.*s", (int)sizeof(pidinfo.pbsd.pbi_name), pidinfo.pbsd.pbi_name);
  }
  sample->tprio = pidinfo.ptinfo.pti_priority;
  sample->status = pidinfo.pbsd.pbi_status;
  sample->flags = pidinfo.pbsd.pbi_flags;
  
  // live and terminated threads in one read, in mach_absolute_time units, so it cannot go backwards
  uint64_t total_timens = ((pidinfo.ptinfo.pti_total_user + pidinfo.ptinfo.pti_total_system) * _top_timebase.numer) / _top_timebase.denom;
  if ((sample->last_timens != 0) && (_timens > sample->last_timens) && (total_timens >= sample->total_timens))
  {
    sample->cpu = (double)(total_timens - sample->total_timens) * 100.0 / (double)(_timens - sample->last_timens);
  }
  else
  {
    sample->cpu = 0.0;
  }
  sample->cpu_known = 1;
  sample->total_timens = total_timens;
  sample->last_timens = _timens;
  
  return (0);
}

int TopInit()
{
  if ((mach_timebase_info(&_top_timebase) != KERN_SUCCESS) || (_top_timebase.denom == 0))
  {
    _top_timebase.numer = 1;
    _top_timebase.denom = 1;
  }
  
  _top_port = MACH_PORT_NULL;
    
  _top_sequence = 0;

  {
    int  mib[2];
    mib[0] = CTL_KERN;
    mib[1] = KERN_ARGMAX;

    size_t size = sizeof(_top_arg_max);
    if (sysctl(mib, 2, &_top_arg_max, &size, NULL, 0) == -1)
    {
      return -1;
    }
    _top_arg_buffer = (char *)malloc(_top_arg_max);
    if (_top_arg_buffer == NULL)
    {
      return -2;
    }
  }
  
  _top_port = mach_host_self();

  rb_tree_new(&_top_pid_tree, node_new);

  CFDictionaryValueCallBacks tableCallbacks = { 0, stringRetain, simpleFree, NULL, stringEqual };
  _top_username_hash_table = CFDictionaryCreateMutable(NULL, 0, NULL, &tableCallbacks);

//  CFDictionaryValueCallBacks table2Callbacks = { 0, NULL, simpleFree, NULL, NULL };
//  _top_hash_table = CFDictionaryCreateMutable(NULL, 0, NULL, &table2Callbacks);
  
  memset(&_top_process_info, 0, sizeof(TopProcessInfo_t));

  return TopSample();
}

void TopSort(void)
{
  _TopProcessInfo_t  *pinfo, *ppinfo;
  
  _top_iterator = NULL;
  
  _top_is_sorted = 1;
    
  _top_process_count = 0;
  
  rb_tree_new(&_top_sorted_tree, node_sorted);
  rb_first(&_top_pid_tree, node_new, pinfo);
  for (; pinfo != rb_tree_nil(&_top_pid_tree); pinfo = ppinfo)
  {
    rb_next(&_top_pid_tree, pinfo, _TopProcessInfo_t, node_new, ppinfo);
    
    if (pinfo->sample.sequence == _top_sequence)
    {
      rb_node_new(&_top_sorted_tree, pinfo, node_sorted);
      rb_insert(&_top_sorted_tree, pinfo, _top_compare_cpu_func, _TopProcessInfo_t, node_sorted);
      
      _top_process_count++;
    }
    else
    {
      _top_destroy(pinfo);
    }
  }
}

typedef struct
{
  pid_t pid;
  double cpu;
} _TopOthersEntry_t;

static int _top_compare_others_entry(const void *a, const void *b)
{
  return _top_compare_pid_key(&((const _TopOthersEntry_t *)a)->pid, &((const _TopOthersEntry_t *)b)->pid);
}

void TopSetOthersCpu(const pid_t* pids, const double* cpus, int count)
{
  _top_others_count = 0;
  if ((count > 0) && (pids != NULL) && (cpus != NULL))
  {
    _TopOthersEntry_t* entries = (_TopOthersEntry_t *)malloc(count * sizeof(_TopOthersEntry_t));
    pid_t* new_pids = (pid_t *)realloc(_top_others_pids, count * sizeof(pid_t));
    if (new_pids != NULL)
    {
      _top_others_pids = new_pids;
    }
    double* new_cpus = (double *)realloc(_top_others_cpus, count * sizeof(double));
    if (new_cpus != NULL)
    {
      _top_others_cpus = new_cpus;
    }
    if ((entries != NULL) && (new_pids != NULL) && (new_cpus != NULL))
    {
      for (int i=0; i<count; i++)
      {
        entries[i].pid = pids[i];
        entries[i].cpu = cpus[i];
      }
      qsort(entries, count, sizeof(_TopOthersEntry_t), _top_compare_others_entry);
      for (int i=0; i<count; i++)
      {
        _top_others_pids[i] = entries[i].pid;
        _top_others_cpus[i] = entries[i].cpu;
      }
      _top_others_count = count;
    }
    free(entries);
  }

  _TopProcessInfo_t *pinfo;
  rb_first(&_top_pid_tree, node_new, pinfo);
  for (; pinfo != rb_tree_nil(&_top_pid_tree); )
  {
    if ((pinfo->sample.sequence == _top_sequence) && (pinfo->sample.cpu_known != 1))
    {
      _top_apply_others_cpu(&pinfo->sample);
    }
    rb_next(&_top_pid_tree, pinfo, _TopProcessInfo_t, node_new, pinfo);
  }

  TopSort();
}

int TopSample(void)
{
  _top_sequence++;

  _top_iterator = NULL;

  _top_is_sorted = 0;

  _top_prev_timens = _timens;
  _top_prev_wall_us = _top_wall_us;
  _timens = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
  {
    // wall clock, to compare with the process start times (pbi_start_tvsec)
    struct timeval tv;
    gettimeofday(&tv, NULL);
    _top_wall_us = ((uint64_t)tv.tv_sec * USEC_PER_SEC) + (uint64_t)tv.tv_usec;
  }

  static pid_t* pids = NULL;
  int num_pids = proc_listallpids(NULL, 0);
  if (num_pids > 0)
  {
    int size = num_pids*sizeof(pid_t);
    pids = realloc(pids, size);
    {
      num_pids = proc_listallpids(pids, size);
      for (int i=0; i<num_pids; i++)
      {
        int err = _top_update_for_pid(pids[i]);
        // -2 (exited since the list was taken) and -3 (zombie) are expected
        if ((err != 0) && (err != -2) && (err != -3))
        {
          fprintf(stderr, "_top_update_for_pid(%d) returned %d\n", pids[i], err);
        }
      }
    }
  }

  TopSort();
  
  return _top_process_count;
}

const TopProcessSample_t* TopIterate(void)
{
  if (_top_is_sorted)
  {
    if (_top_iterator == NULL)
    {
      rb_first(&_top_sorted_tree, node_sorted, _top_iterator);
    }
    else
    {
      rb_next(&_top_sorted_tree, _top_iterator, _TopProcessInfo_t, node_sorted, _top_iterator);
    }
    if (_top_iterator == rb_tree_nil(&_top_sorted_tree))
    {
      _top_iterator = NULL;
    }
  }
  else
  {
    boolean_t dead;

    if (_top_iterator == NULL)
    {
      rb_first(&_top_pid_tree, node_new, _top_iterator);
    }
    else
    {
      rb_next(&_top_pid_tree, _top_iterator, _TopProcessInfo_t, node_new, _top_iterator);
    }

    do
    {
      dead = FALSE;
      
      if (_top_iterator == rb_tree_nil(&_top_pid_tree))
      {
        _top_iterator = NULL;
        break;
      }
      
      if (_top_iterator->sample.sequence != _top_sequence)
      {
        _TopProcessInfo_t  *pinfo;
        
        pinfo = _top_iterator;
        rb_next(&_top_pid_tree, _top_iterator, _TopProcessInfo_t, node_new, _top_iterator);
        
        _top_destroy(pinfo);
        
        dead = TRUE;
      }
    }
    while (dead);
  }

  return (_top_iterator != NULL) ? &_top_iterator->sample : NULL;
}

const char* TopGetUsername(uid_t uid)
{
  const void* k = (const void *)(uintptr_t)uid;
  
  if (!CFDictionaryContainsKey(_top_username_hash_table, k))
  {
    struct passwd *pwd = getpwuid(uid);
    if (pwd == NULL)
      return NULL;
    CFDictionarySetValue(_top_username_hash_table, k, pwd->pw_name);
  }
  return CFDictionaryGetValue(_top_username_hash_table, k);
}

//#define DEBUG_ARGS
#ifdef DEBUG_ARGS
static inline void _spewraw(char *ptr, unsigned long left)
{
  fprintf(stderr, ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>\n");
  for (int i=0; i<left; i++)
  {
    if (isprint(ptr[i]))
    {
      fprintf(stderr, "%c", ptr[i]);
    }
    else
    {
      fprintf(stderr, "[%x]", ptr[i]);
    }
  }
  fprintf(stderr, "\n<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<\n\n\n");
}
static inline void _spewbytes(char *ptr, unsigned long left)
{
  fprintf(stderr, ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>\n");
  for (int i=0; i<left; i++)
  {
    if (ptr[i] == 0)
    {
      fprintf(stderr, "\'\\0\'");
    }
    else if (ptr[i] == '\n')
    {
      fprintf(stderr, "\n");
    }
    else if (isprint(ptr[i]))
    {
      fprintf(stderr, "%c", ptr[i]);
    }
    else
    {
      fprintf(stderr, "[%x]", ptr[i]);
    }
  }
  fprintf(stderr, "\n<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<\n\n\n");
}
#endif

// http://search.cpan.org/src/DURIST/Proc-ProcessTable-0.43/os/darwin.c
TopProcessInfo_t* TopGetArgs(pid_t pid)
{  
  _top_process_info.args_count = 0;
  _top_process_info.args_length = 0;
  _top_process_info.envs_count = 0;
  _top_process_info.envs_length = 0;
  // KERN_PROCARGS2 fails for other users' processes: never leave the previous process's text behind
  if (_top_process_info.command != NULL)
  {
    _top_process_info.command[0] = '\0';
  }
  if (_top_process_info.args_info != NULL)
  {
    _top_process_info.args_info[0] = '\0';
  }
  if (_top_process_info.envs_info != NULL)
  {
    _top_process_info.envs_info[0] = '\0';
  }

  int mib[3];
  mib[0] = CTL_KERN;
  mib[1] = KERN_PROCARGS2;
  mib[2] = pid;
  size_t size = _top_arg_max;
  if (sysctl(mib, 3, _top_arg_buffer, &size, NULL, 0) == KERN_SUCCESS)
  {
#ifdef DEBUG_ARGS
    fprintf(stderr, "\n");
    fprintf(stderr, "\n");
    _spewraw(_top_arg_buffer, size);
    fprintf(stderr, "\n");
    fprintf(stderr, "\n");
#endif
    size_t left = size;
    if (left >= sizeof(int))
    {
      char *data = _top_arg_buffer;
      
      memcpy(&_top_process_info.args_count, data, sizeof(int));
      left -= sizeof(int);
      data += sizeof(int);
      
#ifdef DEBUG_ARGS
      fprintf(stderr, "   args_count: %d\n", _top_process_info.args_count);
#endif
      
      if (left > 0)
      {
        // full path
        size_t length = strlen(data);
        _top_process_info.command = realloc(_top_process_info.command, length+1);
        memcpy(_top_process_info.command, data, length);
        _top_process_info.command[length] ='\0';
        data += length;
        left -= length;
#ifdef DEBUG_ARGS
        fprintf(stderr, "   args_command: %s\n", _top_process_info.command);
#endif
        
        // skip empty space
        while ((left > 0) && (data[0] == '\0'))
        {
          data++;
          left--;
        }
        
        // rest of arguments
        if (left > 0)
        {
          int index = 0;
          while ((left > 0) && (index < _top_process_info.args_count))
          {
            length = strlen(data)+1;
            if (length > 1)
            {
              _top_process_info.args_length += length;
              _top_process_info.args_info = realloc(_top_process_info.args_info, _top_process_info.args_length+1);
              
              char *string = &_top_process_info.args_info[_top_process_info.args_length-length];
              memcpy(string, data, length);
              string[length-1] = '\n';
              string[length] = '\0';
            }
            data += length;
            left -= length;
            index++;
          }
#ifdef DEBUG_ARGS
          fprintf(stderr, "---- args_length: [%d]\n", _top_process_info.args_length);
          fprintf(stderr, "---- args_count: [%d]\n", _top_process_info.args_count);
          _spewbytes(_top_process_info.args_info, _top_process_info.args_length);
          fprintf(stderr, "\n");
#endif
          
          if (left > 0)
          {
            // skip empty space
            while ((left > 0) && (data[0] == '\0'))
            {
              data++;
              left--;
            }
            
            // environment
            if (left > 0)
            {
              while (left > 0)
              {
                length = strlen(data)+1;
                if (length > 1)
                {
                  _top_process_info.envs_length += length;
                  _top_process_info.envs_info = realloc(_top_process_info.envs_info, _top_process_info.envs_length+1);
                  _top_process_info.envs_count++;
                  
                  char *string = &_top_process_info.envs_info[_top_process_info.envs_length-length];
                  memcpy(string, data, length);
                  string[length-1] = '\n';
                  string[length] = '\0';
                }

                data += length;
                left -= length;
              }
#ifdef DEBUG_ARGS
              fprintf(stderr, "---- envs_length: [%d]\n", _top_process_info.envs_length);
              fprintf(stderr, "---- envs_count: [%d]\n", _top_process_info.envs_count);
              _spewbytes(_top_process_info.envs_info, _top_process_info.envs_length);
#endif
            }
          }
        }
      }
    }
  }
  
  struct kinfo_proc kinfo;
  int res = _top_kinfo_for_pid(&kinfo, pid);
  if (res != 0)
  {
    if (_top_process_info.name != NULL)
    {
      _top_process_info.name[0] = '\0';
    }
    fprintf(stderr, "ERR kinfo_for_pid\n");
    return &_top_process_info;
  }
  size = strlen(kinfo.kp_proc.p_comm);
  _top_process_info.name = realloc(_top_process_info.name, size+1);
  strcpy(_top_process_info.name, kinfo.kp_proc.p_comm);
  
  return &_top_process_info;
}

//void top_fini(void)
//{
//  top_pinfo_t *pinfo, *ppinfo;
//
//  /* Deallocate the arg string. */
//  free(top_arg);
//
//  /* Clean up the oinfo structures. */
//  CFRelease(top_oinfo_hash);
//
//  /* Clean up the pinfo structures. */
//  rb_first(&top_ptree, pnode, pinfo);
//  for (; pinfo != rb_tree_nil(&top_ptree); pinfo = ppinfo)
//  {
//    rb_next(&top_ptree, pinfo, top_pinfo_t, pnode, ppinfo);
//
//    /* This removes the pinfo from the tree, and frees pinfo and its data. */
//    top_p_destroy_pinfo(pinfo);
//  }
//
//  /* Clean up the uid->username translation cache. */
//  CFRelease(top_uhash);
//}
