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
static uint64_t _p_timens;

/* Buffer that is large enough to hold the entire argument area of a process. */
static char *_top_arg_buffer;
static int _top_arg_max;

/* Cache of uid->username translations. */
static CFMutableDictionaryRef _top_username_hash_table;
//static CFMutableDictionaryRef _top_hash_table;

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
  return sysctl(mib, (u_int)miblen, kinfo, &len, NULL, 0);
}

static int __attribute__((noinline)) _top_update_for_pid(pid_t pid, double system)
{
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
  
#if 1
  struct proc_taskallinfo pidinfo;
  memset(&pidinfo, 0, sizeof(pidinfo));
  proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &pidinfo, PROC_PIDTASKALLINFO_SIZE);
  if (pinfo->sample.name[0] == 0)
  {
    pinfo->sample.tprio = pidinfo.ptinfo.pti_priority;
    pinfo->sample.status = pidinfo.pbsd.pbi_status;
    pinfo->sample.flags = pidinfo.pbsd.pbi_flags;
    pinfo->sample.ppid = pidinfo.pbsd.pbi_ppid;
    strncpy(pinfo->sample.name, pidinfo.pbsd.pbi_name, TOP_MAX_SAMPLE_NAME_SIZE);
  }
#else
  res = _top_parse_args(pinfo, &kinfo);
  if (res != 0)
  {
    _top_destroy(pinfo);
    return -6;
  }
#endif
  
  struct kinfo_proc kinfo;
  int res = _top_kinfo_for_pid(&kinfo, pid);
  if (res != 0)
  {
    return (-2);
  }
  
  if (kinfo.kp_proc.p_stat == SZOMB)
  {
    return (-3);
  }
  
  pinfo->sample.uid = kinfo.kp_eproc.e_ucred.cr_uid;
  pinfo->sample.sequence_last = pinfo->sample.sequence;
  pinfo->sample.sequence = _top_sequence;
  
  task_name_t task;
  kern_return_t kr = task_name_for_pid(mach_task_self(), pid, &task);
  if (kr != KERN_SUCCESS) {
    return (-4);
  }
  
  struct task_basic_info_64 ti;
  mach_msg_type_number_t count = TASK_BASIC_INFO_64_COUNT;
  kr = task_info(task, TASK_BASIC_INFO_64, (task_info_t)&ti, &count);
  if (kr != KERN_SUCCESS) {
    mach_port_deallocate(mach_task_self(), task);
    _top_destroy(pinfo);
    return (-5);
  }
  pinfo->sample.total_timens = TIME_VALUE_TO_NS(&ti.user_time) + TIME_VALUE_TO_NS(&ti.system_time);
  
#if 0
  struct rusage_info_v5 ri;
  proc_pid_rusage(pid, RUSAGE_INFO_V5, (rusage_info_t)&ri);
  pinfo->sample.total_timens += (ri.ri_user_time + ri.ri_system_time);
#else
  struct task_thread_times_info tti;
  count = TASK_THREAD_TIMES_INFO_COUNT;
  kr = task_info(task, TASK_THREAD_TIMES_INFO, (task_info_t)&tti, &count);
  if (kr != KERN_SUCCESS)
  {
    fprintf(stderr, "ERROR: task_info(TASK_THREAD_TIMES_INFO)\n");
  }
  uint64_t process_total_timens = TIME_VALUE_TO_NS(&tti.user_time)+TIME_VALUE_TO_NS(&tti.system_time);
  pinfo->sample.total_timens += process_total_timens;
#endif
  
  uint64_t last_timens = _p_timens;
  uint64_t last_total_timens = pinfo->sample.p_total_timens;
  unsigned long long elapsed_us = (_timens - last_timens) / NSEC_PER_USEC;
  unsigned long long used_us = (pinfo->sample.total_timens - last_total_timens) / NSEC_PER_USEC;
  pinfo->sample.cpu = (double)used_us*100.0/(double)elapsed_us;
  pinfo->sample.p_total_timens = pinfo->sample.total_timens;
  
  mach_port_deallocate(mach_task_self(), task);
  
  return (0);
}

static double _top_nanos(void)
{
  static mach_timebase_info_data_t mtid = {0, 0};
  if (mtid.numer == 0)
  {
    if (mach_timebase_info(&mtid) != KERN_SUCCESS)
    {
      return -1.0;
    }
  }
  
  static long numProcessors = 0;
  if (numProcessors <= 0)
  {
    numProcessors = sysconf(_SC_NPROCESSORS_ONLN);
    if (numProcessors <= 0)
    {
      return -2.0;
    }
  }
  
  return (mach_absolute_time() * (double)mtid.numer) / (double)mtid.denom;
}

int TopInit()
{
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

int TopSample(void)
{
  static double _top_cpu_system_last = 0.0;

  _top_sequence++;
  
  _top_iterator = NULL;
  
  _top_is_sorted = 0;
  
  double system = 0.0;
  double top_cpu_system = _top_nanos();
  if (top_cpu_system > _top_cpu_system_last)
  {
    system = top_cpu_system - _top_cpu_system_last;
  }
  
  if (_top_sequence != 1)
  {
    _p_timens = _timens;
    _timens = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
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
        int err = _top_update_for_pid(pids[i], system);
        if (err != 0)
        {
          fprintf(stderr, "_top_update_for_pid(%d) returned %d\n", pids[i], err);
        }
      }
    }
  }

  _top_cpu_system_last = top_cpu_system;
  
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

  return &_top_iterator->sample;
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
