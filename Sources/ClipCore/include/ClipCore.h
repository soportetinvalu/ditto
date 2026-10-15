/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef CLIP_CORE_H
#define CLIP_CORE_H
#include <sqlite3.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Keep a literal so Swift's Clang importer exposes the shared 32 MiB limit. */
#define CM_MAX_BYTES 33554432
#define CM_MAX_REPRESENTATIONS 256

typedef struct {
    int item_index;
    const char *type;
    const void *bytes;
    size_t length;
} CMRepresentation;

/* All calls use one serial owner. Errors use sqlite3_errmsg or fixed return codes.
 * capture returns 0=new, 1=deduplicated, negative=error. out_id needs 37 bytes.
 * No clipboard, network, background threads or user-global state are read here. */
int cm_open(const char *path, sqlite3 **out);
int cm_capture(sqlite3 *db, const char *id, const char *fingerprint,
               const char *title, const char *text, const char *source, double now,
               const CMRepresentation *representations, size_t count, char out_id[37]);
int cm_retire(sqlite3 *db, double older_than, int max_count, int64_t max_bytes, double now);
int cm_backup(sqlite3 *db, const char *path);
/* Validate a live connection without reopening a WAL file read-only. Does not close db. */
int cm_validate(sqlite3 *db);
int cm_validate_file(const char *path);
int cm_capture_allowed(int paused, const char *source, const char *excluded_newlines,
                       const char *allowed_newlines, int transient);
#ifdef __cplusplus
}
#endif
#endif
