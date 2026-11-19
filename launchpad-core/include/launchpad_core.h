#ifndef LAUNCHPAD_CORE_H
#define LAUNCHPAD_CORE_H
#include <stdint.h>

int64_t launchpad_disk_usage(const char *path);

int32_t launchpad_catalog_fresh(const char *path, double expected);

int32_t launchpad_receipt_lines(const char *program, void *context,
                                void (*callback)(void *, const uint8_t *, uintptr_t));

int32_t launchpad_import_legacy(const char *path, void *context,
                                void (*callback)(void *, int32_t, const uint8_t *, uintptr_t));

int32_t launchpad_match_moved_apps(const uint8_t *bytes, uintptr_t length, void *context,
                                   void (*callback)(void *, const uint32_t *, uintptr_t));

int32_t launchpad_order_records(const uint8_t *bytes, uintptr_t length, void *context,
                                void (*callback)(void *, const uint32_t *, uintptr_t));

int32_t launchpad_unplaced_records(const uint8_t *bytes, uintptr_t length, void *context,
                                   void (*callback)(void *, const uint32_t *, uintptr_t));

int32_t launchpad_missing_dates(const uint8_t *bytes, uintptr_t length, void *context,
                                void (*callback)(void *, const uint32_t *, uintptr_t));

int32_t launchpad_catalog_encode(const uint8_t *bytes, uintptr_t length, void *context,
                                 void (*callback)(void *, const uint8_t *, uintptr_t));

int32_t launchpad_aerial_assets(const char *path, void *context,
                                void (*callback)(void *, const uint8_t *, uintptr_t));;
int32_t launchpad_catalog_decode(const uint8_t *bytes, uintptr_t length, void *context,
                                 void (*callback)(void *, const uint8_t *, uintptr_t));

int32_t launchpad_safe_identifier(const uint8_t *bytes, uintptr_t length);
int64_t launchpad_classify_special_key(int64_t subtype, int64_t data1);

int32_t launchpad_read_file(const char *path, void *context,
                            void (*callback)(void *, const uint8_t *, uintptr_t));

int32_t launchpad_directory_entries(const char *path, void *context,
                                    void (*callback)(void *, const uint8_t *, uintptr_t));

int32_t launchpad_photo_links(const char *path, void *context,
                              void (*callback)(void *, const uint8_t *, uintptr_t, const uint8_t *, uintptr_t));
int32_t launchpad_access_time(const char *path, double *result);

int32_t launchpad_nested_exists(const char *root, const uint8_t *names, uintptr_t length);

int32_t launchpad_read_file_limited(const char *path, uintptr_t limit, void *context,
                                    void (*callback)(void *, const uint8_t *, uintptr_t));

void *launchpad_read_owned(const char *path, uintptr_t limit, uint8_t **data, uintptr_t *length);
void launchpad_read_owned_free(void *handle);

int32_t launchpad_write_file_atomic(const char *path, const uint8_t *bytes, uintptr_t length);

int32_t launchpad_write_cache_atomic(const char *path, const uint8_t *bytes, uintptr_t length);

int32_t launchpad_search_tier(const uint8_t *bytes, uintptr_t length);

int32_t launchpad_match_graphemes(const uint8_t *bytes, uintptr_t length);

int32_t launchpad_layout_reorder(const uintptr_t *counts, uintptr_t page_count,
                                 const uint8_t *selected, uintptr_t item_count,
                                 uintptr_t leader, uintptr_t target, uintptr_t slot, uintptr_t capacity,
                                 void *context, void (*callback)(void *, const uintptr_t *, uintptr_t,
                                                                 const uintptr_t *, uintptr_t, uintptr_t));

int32_t launchpad_layout_move_one(const uintptr_t *counts, uintptr_t page_count,
                                  uintptr_t source, uintptr_t source_index, uintptr_t target,
                                  uintptr_t slot, uintptr_t capacity, void *context,
                                  void (*callback)(void *, uintptr_t, const uintptr_t *, uintptr_t));;

int32_t launchpad_layout_repack(uintptr_t item_count, uintptr_t capacity, void *context,
                                void (*callback)(void *, const uintptr_t *, uintptr_t,
                                                 const uintptr_t *, uintptr_t, uintptr_t));

int32_t launchpad_layout_overflow(const uintptr_t *counts, uintptr_t page_count,
                                  uintptr_t start, uintptr_t capacity, void *context,
                                  void (*callback)(void *, const uintptr_t *, uintptr_t));
void launchpad_trim_icon_cache(const char *path, int64_t budget);

void *launchpad_memory_cache_new(uint64_t max_cost, uintptr_t max_items);
void launchpad_memory_cache_free(void *cache);
void launchpad_memory_cache_clear(void *cache);
uint64_t launchpad_memory_cache_touch(void *cache, const uint8_t *bytes, uintptr_t length);
uint64_t launchpad_memory_cache_put(void *cache, const uint8_t *bytes, uintptr_t length, uint64_t cost,
                                   void *context, void (*callback)(void *, const uint64_t *, uintptr_t));
int32_t launchpad_scan_apps(const char *path, int32_t recursive, void *context,
                           void (*callback)(void *, const char *, int32_t));

void *launchpad_watch_start(const char *const *paths, uintptr_t count, double latency, void *context,
                            void (*callback)(void *, const char *const *, uintptr_t, int32_t));
void launchpad_watch_stop(void *watcher);
#endif
