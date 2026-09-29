// SMC 读取实现：对本仓库公共内核 ABI 的独立编写（122 行，非派生自 2006 devnull 的 GPL 工具族）。
// 来源与许可证边界见根目录 THIRD_PARTY_NOTICES.md——改这个文件前先读它。
#ifndef DEVBAR_SMC_H
#define DEVBAR_SMC_H
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
uint32_t smc_open(void);
void smc_close(uint32_t connection);
int smc_read(uint32_t connection, const char *key, double *value);
int smc_key_at(uint32_t connection, uint32_t index, char key[5]);
int dsb_proc_diskio(pid_t pid, uint64_t *out_read, uint64_t *out_write);
int dsb_pid_count(void);
int dsb_list_pids(int *buf, int count);
// 一次调用拿到 进程名 + CPU 时间(纳秒) + 物理实占 + 常驻 RSS；任一失败返回 -1
int dsb_proc_info(pid_t pid, char *name, size_t name_sz, uint64_t *cpu_ns, uint64_t *footprint, uint64_t *resident);
#endif
