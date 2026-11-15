#ifndef LAUNCHPAD_CORE_H
#define LAUNCHPAD_CORE_H
#include <stdint.h>

int64_t launchpad_disk_usage(const char *path);
void launchpad_trim_icon_cache(const char *path, int64_t budget);
int32_t launchpad_scan_apps(const char *path, int32_t recursive, void *context,
                           void (*callback)(void *, const char *, int32_t));
#endif
