#ifndef CACTIVITY_H
#define CACTIVITY_H
#include <stdint.h>
#include <stddef.h>
typedef struct {
 int32_t pid, parent_pid;
 uint32_t uid;
 uint32_t is_stopped;
 uint64_t start_sec, start_usec, memory_bytes, cpu_ns, disk_read_bytes, disk_write_bytes;
 char name[256];
} ActivityProcessMetrics;
int activity_list_pids(int32_t *buffer, int byte_capacity);
int activity_read_process(int32_t pid, ActivityProcessMetrics *result);
int activity_process_path(int32_t pid, char *buffer, uint32_t capacity);
int activity_process_cwd(int32_t pid, char *buffer, uint32_t capacity);
#endif
