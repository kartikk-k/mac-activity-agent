#include "CActivity.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/proc.h>
#include <sys/resource.h>
#include <string.h>
#include <mach/mach_time.h>
#include <pthread.h>
static mach_timebase_info_data_t activity_timebase;
static pthread_once_t activity_timebase_once = PTHREAD_ONCE_INIT;
static void activity_initialize_timebase(void) { mach_timebase_info(&activity_timebase); }
static uint64_t activity_cpu_nanoseconds(uint64_t ticks) {
 pthread_once(&activity_timebase_once, activity_initialize_timebase);
 return (uint64_t)((__uint128_t)ticks * activity_timebase.numer / activity_timebase.denom);
}
int activity_list_pids(int32_t *buffer, int byte_capacity) {
 return proc_listpids(PROC_ALL_PIDS, 0, buffer, byte_capacity);
}
int activity_read_process(int32_t pid, ActivityProcessMetrics *r) {
 struct proc_bsdinfo b = {0};
 if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, sizeof(b)) != sizeof(b)) return 0;
 memset(r, 0, sizeof(*r));
 r->pid = pid; r->parent_pid = b.pbi_ppid; r->uid = b.pbi_uid;
 r->is_stopped = b.pbi_status == SSTOP;
 r->start_sec = b.pbi_start_tvsec; r->start_usec = b.pbi_start_tvusec;
 strlcpy(r->name, b.pbi_name[0] ? b.pbi_name : b.pbi_comm, sizeof(r->name));
 struct rusage_info_v2 u = {0};
 if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&u) == 0) {
  r->memory_bytes = u.ri_phys_footprint ? u.ri_phys_footprint : u.ri_resident_size;
  r->cpu_ns = activity_cpu_nanoseconds(u.ri_user_time + u.ri_system_time);
  r->disk_read_bytes = u.ri_diskio_bytesread; r->disk_write_bytes = u.ri_diskio_byteswritten;
 } else {
  struct proc_taskinfo t = {0};
  if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &t, sizeof(t)) == sizeof(t)) {
   r->memory_bytes = t.pti_resident_size; r->cpu_ns = activity_cpu_nanoseconds(t.pti_total_user + t.pti_total_system);
  }
 }
 return 1;
}
int activity_process_path(int32_t pid, char *buffer, uint32_t capacity) {
 return proc_pidpath(pid, buffer, capacity);
}
int activity_process_cwd(int32_t pid, char *buffer, uint32_t capacity) {
 struct proc_vnodepathinfo v = {0};
 if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &v, sizeof(v)) != sizeof(v)) return 0;
 strlcpy(buffer, v.pvi_cdir.vip_path, capacity);
 return buffer[0] != 0;
}
