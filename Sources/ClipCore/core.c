/* SPDX-License-Identifier: GPL-3.0-only
 * Original implementation for Memoria Local. No Ditto source copied.
 */
#include "ClipCore.h"
#include <string.h>
#include <stdio.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

static const char *schema =
"CREATE TABLE groups(id TEXT PRIMARY KEY,name TEXT NOT NULL,parent_id TEXT REFERENCES groups(id) ON DELETE RESTRICT);"
"CREATE TABLE clips(id TEXT PRIMARY KEY CHECK(length(id)=36),fingerprint TEXT NOT NULL,"
"title TEXT NOT NULL,plain_text TEXT NOT NULL,source TEXT NOT NULL,created REAL NOT NULL,"
"last_seen REAL NOT NULL,last_used REAL,copies INTEGER NOT NULL DEFAULT 1,"
"favorite INTEGER NOT NULL DEFAULT 0,protected INTEGER NOT NULL DEFAULT 0,"
"sticky INTEGER NOT NULL DEFAULT 0 CHECK(sticky BETWEEN -1 AND 1),"
"group_id TEXT REFERENCES groups(id) ON DELETE SET NULL,alias TEXT COLLATE NOCASE,"
"deleted_at REAL,total_bytes INTEGER NOT NULL);"
"CREATE UNIQUE INDEX clips_fingerprint ON clips(fingerprint) WHERE deleted_at IS NULL;"
"CREATE UNIQUE INDEX clips_alias ON clips(alias) WHERE alias IS NOT NULL AND alias<>'' AND deleted_at IS NULL;"
"CREATE INDEX clips_order ON clips(deleted_at,sticky,last_seen);"
"CREATE TABLE representations(clip_id TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,"
"item_index INTEGER NOT NULL CHECK(item_index>=0),type TEXT NOT NULL,payload BLOB NOT NULL,"
"PRIMARY KEY(clip_id,item_index,type));"
"CREATE TABLE buffers(slot INTEGER PRIMARY KEY CHECK(slot BETWEEN 1 AND 3),clip_id TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE);"
"PRAGMA user_version=1;";

static int exec(sqlite3 *db,const char *sql) { return sqlite3_exec(db,sql,0,0,0); }
static void text(sqlite3_stmt *s,int n,const char *v) { sqlite3_bind_text(s,n,v?v:"",-1,SQLITE_TRANSIENT); }

int cm_open(const char *path,sqlite3 **out) {
    *out = NULL;
    int rc=sqlite3_open_v2(path,out,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,NULL);
    if(rc!=SQLITE_OK) return rc;
    sqlite3_busy_timeout(*out,3000);
    sqlite3_stmt *s=NULL;
    rc=sqlite3_prepare_v2(*out,"PRAGMA user_version",-1,&s,NULL);
    if(rc!=SQLITE_OK) return rc;
    int version=sqlite3_step(s)==SQLITE_ROW?sqlite3_column_int(s,0):-1;
    sqlite3_finalize(s);
    if(version>1 || version<0) return SQLITE_MISMATCH;
    if(strcmp(path,":memory:")!=0) chmod(path,0600);
    rc=exec(*out,"PRAGMA foreign_keys=ON;PRAGMA journal_mode=WAL;PRAGMA synchronous=FULL;PRAGMA trusted_schema=OFF;");
    if(rc!=SQLITE_OK) return rc;
    if(version==0) {
        rc=exec(*out,"BEGIN IMMEDIATE");
        if(rc==SQLITE_OK) rc=exec(*out,schema);
        if(rc==SQLITE_OK) rc=exec(*out,"COMMIT");
        else exec(*out,"ROLLBACK");
    }
    return rc;
}

int cm_capture(sqlite3 *db,const char *id,const char *fingerprint,const char *title,
               const char *plain,const char *source,double now,const CMRepresentation *reps,
               size_t count,char out_id[37]) {
    if(!db || !out_id || !id || strlen(id)!=36 || !fingerprint || !*fingerprint || !reps || count==0 || count>CM_MAX_REPRESENTATIONS) return -SQLITE_MISUSE;
    size_t total=0;
    for(size_t i=0;i<count;i++) {
        if(reps[i].item_index<0 || !reps[i].type || !*reps[i].type || !reps[i].bytes || reps[i].length>CM_MAX_BYTES) return -SQLITE_TOOBIG;
        total+=reps[i].length;
        if(total>CM_MAX_BYTES) return -SQLITE_TOOBIG;
    }
    int rc=exec(db,"SAVEPOINT capture");
    if(rc!=SQLITE_OK) return -rc;
    sqlite3_stmt *s=NULL;
    int duplicate=0;
    rc=sqlite3_prepare_v2(db,"SELECT id FROM clips WHERE fingerprint=? AND deleted_at IS NULL",-1,&s,NULL);
    if(rc!=SQLITE_OK) goto fail;
    text(s,1,fingerprint);
    int step=sqlite3_step(s);
    if(step==SQLITE_ROW) {
        snprintf(out_id,37,"%s",sqlite3_column_text(s,0)); duplicate=1;
    } else if(step!=SQLITE_DONE) { rc=step; goto fail; }
    sqlite3_finalize(s);s=NULL;
    if(duplicate) {
        rc=sqlite3_prepare_v2(db,"UPDATE clips SET last_seen=?,copies=copies+1 WHERE id=?",-1,&s,NULL);
        if(rc!=SQLITE_OK) goto fail;
        sqlite3_bind_double(s,1,now);text(s,2,out_id);
    } else {
        snprintf(out_id,37,"%s",id);
        rc=sqlite3_prepare_v2(db,"INSERT INTO clips(id,fingerprint,title,plain_text,source,created,last_seen,total_bytes) VALUES(?,?,?,?,?,?,?,?)",-1,&s,NULL);
        if(rc!=SQLITE_OK) goto fail;
        text(s,1,id);text(s,2,fingerprint);text(s,3,title);text(s,4,plain);text(s,5,source);
        sqlite3_bind_double(s,6,now);sqlite3_bind_double(s,7,now);sqlite3_bind_int64(s,8,(sqlite3_int64)total);
    }
    rc=sqlite3_step(s);sqlite3_finalize(s);s=NULL;
    if(rc!=SQLITE_DONE) goto fail;
    if(!duplicate) for(size_t i=0;i<count;i++) {
        rc=sqlite3_prepare_v2(db,"INSERT INTO representations VALUES(?,?,?,?)",-1,&s,NULL);
        if(rc!=SQLITE_OK) goto fail;
        text(s,1,id);sqlite3_bind_int(s,2,reps[i].item_index);text(s,3,reps[i].type);
        sqlite3_bind_blob(s,4,reps[i].bytes,(int)reps[i].length,SQLITE_TRANSIENT);
        rc=sqlite3_step(s);sqlite3_finalize(s);s=NULL;
        if(rc!=SQLITE_DONE) goto fail;
    }
    rc=exec(db,"RELEASE capture");
    return rc==SQLITE_OK?duplicate:-rc;
fail:
    if(s) sqlite3_finalize(s);
    exec(db,"ROLLBACK TO capture;RELEASE capture;");
    return -rc;
}

int cm_retire(sqlite3 *db,double older,int max_count,int64_t max_bytes,double now) {
    /* Protection/favorites/sticky are orthogonal flags. All prevent automatic retirement.
       Count/size budgets include protected records: exceeding a budget may be unavoidable. */
    if(max_count<1 || max_bytes<1) return SQLITE_MISUSE;
    int rc=exec(db,"SAVEPOINT retention"); if(rc!=SQLITE_OK) return rc;
    sqlite3_stmt *s=NULL;
    const char *sql=
      "WITH ranked AS (SELECT id,created,favorite,protected,sticky,"
      "ROW_NUMBER() OVER(ORDER BY last_seen DESC,id) AS n,"
      "SUM(total_bytes) OVER(ORDER BY last_seen DESC,id) AS bytes FROM clips WHERE deleted_at IS NULL) "
      "UPDATE clips SET deleted_at=? WHERE id IN (SELECT id FROM ranked WHERE favorite=0 AND protected=0 AND sticky=0 AND (created<? OR n>? OR bytes>?))";
    rc=sqlite3_prepare_v2(db,sql,-1,&s,NULL);
    if(rc==SQLITE_OK) {
        sqlite3_bind_double(s,1,now);sqlite3_bind_double(s,2,older);
        sqlite3_bind_int(s,3,max_count);sqlite3_bind_int64(s,4,max_bytes);
        rc=sqlite3_step(s); if(rc==SQLITE_DONE) rc=SQLITE_OK;
    }
    sqlite3_finalize(s);
    if(rc==SQLITE_OK) rc=exec(db,"RELEASE retention");
    else exec(db,"ROLLBACK TO retention;RELEASE retention;");
    return rc;
}

int cm_backup(sqlite3 *db,const char *path) {
    sqlite3 *dest=NULL;
    // Reserve the name atomically; never clobber a user's existing backup or symlink.
    int fd=open(path,O_WRONLY|O_CREAT|O_EXCL,0600);
    if(fd<0) return SQLITE_ERROR;
    close(fd);
    int rc=sqlite3_open_v2(path,&dest,SQLITE_OPEN_READWRITE,NULL);
    if(rc!=SQLITE_OK) { if(dest) sqlite3_close(dest);return rc; }
    chmod(path,0600);
    /* Backups must be self-contained files, independent of WAL/SHM sidecars. */
    rc=exec(dest,"PRAGMA journal_mode=DELETE");
    if(rc==SQLITE_OK) {
        sqlite3_backup *b=sqlite3_backup_init(dest,"main",db,"main");
        if(!b) {rc=sqlite3_errcode(dest);} else {
            rc=sqlite3_backup_step(b,-1);
            int finish=sqlite3_backup_finish(b);
            rc=rc==SQLITE_DONE?finish:rc;
        }
    }
    if(rc==SQLITE_OK) rc=exec(dest,"PRAGMA journal_mode=DELETE");
    int closed=sqlite3_close(dest);
    return rc==SQLITE_OK?closed:rc;
}

int cm_validate_file(const char *path) {
    sqlite3 *db=NULL;sqlite3_stmt *s=NULL;
    int rc=sqlite3_open_v2(path,&db,SQLITE_OPEN_READONLY,NULL);
    if(rc!=SQLITE_OK) goto done;
    rc=sqlite3_prepare_v2(db,"PRAGMA quick_check",-1,&s,NULL);
    if(rc!=SQLITE_OK) goto done;
    rc=sqlite3_step(s)==SQLITE_ROW && strcmp((const char*)sqlite3_column_text(s,0),"ok")==0?SQLITE_OK:SQLITE_CORRUPT;
    sqlite3_finalize(s);s=NULL;
    if(rc!=SQLITE_OK) goto done;
    rc=sqlite3_prepare_v2(db,"SELECT (SELECT user_version FROM pragma_user_version), (SELECT count(*) FROM clips), (SELECT count(*) FROM representations), (SELECT count(*) FROM groups), (SELECT count(*) FROM buffers)",-1,&s,NULL);
    if(rc!=SQLITE_OK) goto done;
    rc=sqlite3_step(s)==SQLITE_ROW && sqlite3_column_int(s,0)==1?SQLITE_OK:SQLITE_MISMATCH;
    sqlite3_finalize(s);s=NULL;
    if(rc!=SQLITE_OK) goto done;
    rc=sqlite3_prepare_v2(db,"PRAGMA foreign_key_check",-1,&s,NULL);
    if(rc==SQLITE_OK) rc=sqlite3_step(s)==SQLITE_DONE?SQLITE_OK:SQLITE_CONSTRAINT;
    sqlite3_finalize(s);s=NULL;
    if(rc!=SQLITE_OK) goto done;
    // Restore imports only typed, bounded records. This also verifies every column used by Swift.
    const char *invalid=
      "SELECT 1 FROM clips WHERE typeof(id)<>'text' OR length(id)<>36 OR typeof(fingerprint)<>'text' "
      "OR typeof(title)<>'text' OR typeof(plain_text)<>'text' OR typeof(source)<>'text' "
      "OR typeof(created) NOT IN ('real','integer') OR typeof(last_seen) NOT IN ('real','integer') "
      "OR (last_used IS NOT NULL AND typeof(last_used) NOT IN ('real','integer')) "
      "OR typeof(copies)<>'integer' OR favorite NOT IN (0,1) OR protected NOT IN (0,1) OR sticky NOT IN (-1,0,1) "
      "OR (group_id IS NOT NULL AND typeof(group_id)<>'text') OR (alias IS NOT NULL AND typeof(alias)<>'text') "
      "OR (deleted_at IS NOT NULL AND typeof(deleted_at) NOT IN ('real','integer')) OR typeof(total_bytes)<>'integer' "
      "OR total_bytes<0 OR total_bytes>33554432 "
      "UNION ALL SELECT 1 FROM representations WHERE typeof(clip_id)<>'text' OR typeof(item_index)<>'integer' "
      "OR item_index<0 OR typeof(type)<>'text' OR type='' OR typeof(payload)<>'blob' OR length(payload)>33554432 "
      "UNION ALL SELECT 1 FROM groups WHERE typeof(id)<>'text' OR typeof(name)<>'text' OR (parent_id IS NOT NULL AND typeof(parent_id)<>'text') "
      "UNION ALL SELECT 1 FROM buffers WHERE typeof(slot)<>'integer' OR slot NOT BETWEEN 1 AND 3 OR typeof(clip_id)<>'text' LIMIT 1";
    rc=sqlite3_prepare_v2(db,invalid,-1,&s,NULL);
    if(rc==SQLITE_OK) rc=sqlite3_step(s)==SQLITE_DONE?SQLITE_OK:SQLITE_MISMATCH;
done:
    if(s) sqlite3_finalize(s);
    if(db) sqlite3_close(db);
    return rc;
}

static int contains_line(const char *lines,const char *needle) {
    if(!lines || !needle) return 0;
    size_t len=strlen(needle); const char *p=lines;
    while(*p) { const char *end=strchr(p,'\n');size_t n=end?(size_t)(end-p):strlen(p);
        if(n==len && memcmp(p,needle,n)==0) return 1;
        if(!end) break;
        p=end+1;
    }
    return 0;
}
int cm_capture_allowed(int paused,const char *source,const char *excluded,const char *allowed,int transient) {
    if(paused || transient || !source || !*source) return 0;
    if(contains_line(excluded,source)) return 0;
    if(allowed && *allowed && !contains_line(allowed,source)) return 0;
    return 1;
}
