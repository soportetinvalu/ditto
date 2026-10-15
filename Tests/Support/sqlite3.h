/* SPDX-License-Identifier: GPL-3.0-only
 * Test-only declarations for the stable SQLite C ABI when a Linux executor has
 * the real SQLite runtime but no development header. NO SQLite implementation,
 * fake SQL engine or stubs live here. macOS builds must use the SDK sqlite3.h.
 * Keep limited to APIs exercised by core.c/core_tests.c.
 */
#ifndef CM_TEST_SQLITE3_ABI_H
#define CM_TEST_SQLITE3_ABI_H
#ifndef CM_TEST_RUNTIME_ABI
#error "This header is only for portable runtime-linked tests, not production"
#endif
#include <stdint.h>
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
typedef struct sqlite3_backup sqlite3_backup;
typedef int64_t sqlite3_int64;
typedef void (*sqlite3_destructor_type)(void*);
#define SQLITE_OK 0
#define SQLITE_ERROR 1
#define SQLITE_MISMATCH 20
#define SQLITE_MISUSE 21
#define SQLITE_CORRUPT 11
#define SQLITE_TOOBIG 18
#define SQLITE_CONSTRAINT 19
#define SQLITE_ROW 100
#define SQLITE_DONE 101
#define SQLITE_OPEN_READONLY 0x00000001
#define SQLITE_OPEN_READWRITE 0x00000002
#define SQLITE_OPEN_CREATE 0x00000004
#define SQLITE_OPEN_EXCLUSIVE 0x00000010
#define SQLITE_OPEN_FULLMUTEX 0x00010000
#define SQLITE_TRANSIENT ((sqlite3_destructor_type)-1)
int sqlite3_open(const char*,sqlite3**);
int sqlite3_open_v2(const char*,sqlite3**,int,const char*);
int sqlite3_close(sqlite3*);
int sqlite3_busy_timeout(sqlite3*,int);
int sqlite3_exec(sqlite3*,const char*,int(*)(void*,int,char**,char**),void*,char**);
int sqlite3_prepare_v2(sqlite3*,const char*,int,sqlite3_stmt**,const char**);
int sqlite3_step(sqlite3_stmt*);
int sqlite3_finalize(sqlite3_stmt*);
int sqlite3_column_int(sqlite3_stmt*,int);
const unsigned char *sqlite3_column_text(sqlite3_stmt*,int);
int sqlite3_bind_text(sqlite3_stmt*,int,const char*,int,sqlite3_destructor_type);
int sqlite3_bind_double(sqlite3_stmt*,int,double);
int sqlite3_bind_int(sqlite3_stmt*,int,int);
int sqlite3_bind_int64(sqlite3_stmt*,int,sqlite3_int64);
int sqlite3_bind_blob(sqlite3_stmt*,int,const void*,int,sqlite3_destructor_type);
int sqlite3_errcode(sqlite3*);
const char *sqlite3_libversion(void);
sqlite3_backup *sqlite3_backup_init(sqlite3*,const char*,sqlite3*,const char*);
int sqlite3_backup_step(sqlite3_backup*,int);
int sqlite3_backup_finish(sqlite3_backup*);
#endif
