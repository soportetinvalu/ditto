/* SPDX-License-Identifier: GPL-3.0-only */
#include "ClipCore.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>

static int assertions=0;
#define CHECK(x) do { assertions++; if(!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);exit(1); } } while(0)
static int integer(sqlite3 *db,const char *sql) {
    sqlite3_stmt *s=NULL;CHECK(sqlite3_prepare_v2(db,sql,-1,&s,NULL)==SQLITE_OK);
    CHECK(sqlite3_step(s)==SQLITE_ROW);int v=sqlite3_column_int(s,0);sqlite3_finalize(s);return v;
}
static void sql(sqlite3 *db,const char *s) { CHECK(sqlite3_exec(db,s,NULL,NULL,NULL)==SQLITE_OK); }
static const char *ids[]={"00000000-0000-0000-0000-000000000001","00000000-0000-0000-0000-000000000002","00000000-0000-0000-0000-000000000003","00000000-0000-0000-0000-000000000004","00000000-0000-0000-0000-000000000005"};
int main(int argc,char **argv) {
    CHECK(argc==2);
    char path[2048],backup[2048],bad[2048];
    snprintf(path,sizeof path,"%s/history.sqlite",argv[1]);
    snprintf(backup,sizeof backup,"%s/backup.sqlite",argv[1]);
    snprintf(bad,sizeof bad,"%s/not-a-db",argv[1]);
    sqlite3 *db=NULL;CHECK(cm_open(path,&db)==SQLITE_OK);
    CHECK(integer(db,"PRAGMA user_version")==1);CHECK(integer(db,"PRAGMA foreign_keys")==1);
    const unsigned char bytes[]={0,255,1,0,77};
    const char *text="Hola ñ 👩🏽‍💻\n100%_";
    CMRepresentation reps[]={{0,"public.utf8-plain-text",text,strlen(text)}, {0,"public.html","<b>hola</b>",11},{1,"public.png",bytes,sizeof bytes}};
    char out[37];
    CHECK(cm_capture(db,ids[0],"sha1","Título",text,"test.app",100,reps,3,out)==0);
    CHECK(strcmp(out,ids[0])==0);
    CHECK(integer(db,"SELECT count(*) FROM representations")==3);
    CHECK(integer(db,"SELECT length(payload) FROM representations WHERE type='public.png'")==5);
    CHECK(integer(db,"SELECT hex(payload)='00FF01004D' FROM representations WHERE type='public.png'")==1);
    CHECK(cm_capture(db,ids[1],"sha1","Otra",text,"test.app",110,reps,3,out)==1);
    CHECK(strcmp(out,ids[0])==0);CHECK(integer(db,"SELECT count(*) FROM clips")==1);
    CHECK(integer(db,"SELECT copies FROM clips")==2);
    sql(db,"BEGIN IMMEDIATE");
    CHECK(cm_capture(db,ids[1],"sha1","Otra",text,"test.app",115,reps,3,out)==1);
    CHECK(integer(db,"SELECT copies FROM clips")==3);
    sql(db,"ROLLBACK");CHECK(integer(db,"SELECT copies FROM clips")==2);
    // Literal wildcard/query-like text must not be treated as SQL.
    CHECK(integer(db,"SELECT count(*) FROM clips WHERE instr(plain_text,'100%_')>0")==1);
    CHECK(integer(db,"SELECT count(*) FROM clips WHERE instr(plain_text,''' OR 1=1 --')>0")==0);
    // A duplicate representation violates the primary key and must roll back the clip itself.
    CMRepresentation invalid[]={reps[0],reps[0]};
    CHECK(cm_capture(db,ids[1],"invalid","bad","","test.app",120,invalid,2,out)<0);
    CHECK(integer(db,"SELECT count(*) FROM clips WHERE fingerprint='invalid'")==0);
    CMRepresentation huge={0,"public.png",bytes,(size_t)CM_MAX_BYTES+1};
    CHECK(cm_capture(db,ids[1],"big","bad","","test.app",120,&huge,1,out)==-SQLITE_TOOBIG);
    CHECK(cm_capture(db,ids[1],"empty","bad","","test.app",120,reps,0,out)<0);
    CHECK(cm_capture(db,"malformed","bad","bad","","test.app",120,reps,1,out)<0);
    sql(db,"INSERT INTO groups VALUES('parent','Padre',NULL);INSERT INTO groups VALUES('child','Hijo','parent');UPDATE clips SET group_id='child',protected=1 WHERE fingerprint='sha1'");
    CHECK(cm_capture(db,ids[1],"sha2","vieja","antigua","test.app",10,reps,1,out)==0);
    CHECK(cm_capture(db,ids[2],"sha3","favorita","favorita","test.app",20,reps,1,out)==0);
    sql(db,"UPDATE clips SET favorite=1 WHERE fingerprint='sha3'");
    CHECK(cm_capture(db,ids[3],"sha4","fijada","fijada","test.app",30,reps,1,out)==0);
    sql(db,"UPDATE clips SET sticky=-1 WHERE fingerprint='sha4'");
    CHECK(cm_capture(db,ids[4],"sha5","nueva","nueva","test.app",300,reps,1,out)==0);
    CHECK(cm_retire(db,50,2,CM_MAX_BYTES,400)==SQLITE_OK);
    CHECK(integer(db,"SELECT count(*) FROM clips WHERE deleted_at IS NOT NULL")==1);
    CHECK(integer(db,"SELECT count(*) FROM clips WHERE deleted_at IS NULL AND (protected=1 OR favorite=1 OR sticky<>0)")==3);
    CHECK(integer(db,"SELECT count(*) FROM representations WHERE clip_id='00000000-0000-0000-0000-000000000002'")==1);
    // Restore soft-retired record, no BLOB data was lost.
    sql(db,"UPDATE clips SET deleted_at=NULL WHERE fingerprint='sha2'");
    CHECK(integer(db,"SELECT count(*) FROM clips WHERE deleted_at IS NULL")==5);
    CHECK(integer(db,"WITH RECURSIVE tree(id) AS(SELECT 'parent' UNION SELECT groups.id FROM groups JOIN tree ON groups.parent_id=tree.id) SELECT count(*) FROM clips WHERE group_id IN tree")==1);
    CHECK(sqlite3_exec(db,"DELETE FROM groups WHERE id='parent'",NULL,NULL,NULL)==SQLITE_CONSTRAINT);
    sql(db,"DELETE FROM groups WHERE id='child'");CHECK(integer(db,"SELECT count(*) FROM clips WHERE group_id IS NOT NULL")==0);
    sql(db,"INSERT INTO buffers VALUES(1,'00000000-0000-0000-0000-000000000001')");
    CHECK(sqlite3_exec(db,"INSERT INTO buffers VALUES(4,'00000000-0000-0000-0000-000000000001')",NULL,NULL,NULL)==SQLITE_CONSTRAINT);
    // Retention by size/count also moves to trash, preserving protected rows.
    CHECK(cm_retire(db,0,1,1,500)==SQLITE_OK);
    CHECK(integer(db,"SELECT count(*) FROM clips WHERE deleted_at IS NULL AND protected=1")==1);
    CHECK(integer(db,"SELECT count(*) FROM clips WHERE deleted_at IS NOT NULL")==2);
    CHECK(cm_retire(db,0,0,1,500)==SQLITE_MISUSE);
    CHECK(cm_backup(db,backup)==SQLITE_OK);CHECK(cm_validate_file(backup)==SQLITE_OK);
    CHECK(cm_backup(db,backup)!=SQLITE_OK);CHECK(cm_validate_file(backup)==SQLITE_OK);
    sqlite3 *other=NULL;CHECK(cm_open(backup,&other)==SQLITE_OK);
    // Validate the already-open WAL connection before any further read/write.
    CHECK(cm_validate(other)==SQLITE_OK);CHECK(cm_validate(NULL)==SQLITE_MISUSE);
    CHECK(integer(other,"SELECT count(*) FROM clips")==5);CHECK(integer(other,"SELECT count(*) FROM representations")==7);
    sqlite3_close(other);
    // Explicit permanent delete cascades only selected record's reps/buffer.
    sql(db,"DELETE FROM clips WHERE fingerprint='sha1'");
    CHECK(integer(db,"SELECT count(*) FROM buffers")==0);CHECK(integer(db,"SELECT count(*) FROM representations")==4);
    sqlite3_close(db);db=NULL;CHECK(cm_open(path,&db)==SQLITE_OK);
    CHECK(integer(db,"SELECT count(*) FROM clips")==4);
    sqlite3_close(db);db=NULL;
    FILE *f=fopen(bad,"w");CHECK(f!=NULL);fputs("not sqlite",f);fclose(f);
    CHECK(cm_validate_file(bad)!=SQLITE_OK);
    CHECK(sqlite3_open(backup,&other)==SQLITE_OK);
    sql(other,"UPDATE clips SET plain_text=x'FF' WHERE fingerprint='sha2'");sqlite3_close(other);
    CHECK(cm_validate_file(backup)!=SQLITE_OK);
    CHECK(sqlite3_open(backup,&other)==SQLITE_OK);
    sql(other,"UPDATE clips SET plain_text='restored' WHERE fingerprint='sha2'");sqlite3_close(other);
    CHECK(cm_validate_file(backup)==SQLITE_OK);
    // Unknown future versions are rejected without migration or deletion.
    CHECK(sqlite3_open(backup,&other)==SQLITE_OK);sql(other,"PRAGMA user_version=99");sqlite3_close(other);
    CHECK(cm_validate_file(backup)!=SQLITE_OK);
    CHECK(cm_open(backup,&db)==SQLITE_MISMATCH);CHECK(integer(db,"PRAGMA user_version")==99);sqlite3_close(db);
    CHECK(cm_capture_allowed(0,"com.safe","com.secret","",0)==1);
    CHECK(cm_capture_allowed(1,"com.safe","","",0)==0);
    CHECK(cm_capture_allowed(0,"com.secret","com.secret","",0)==0);
    CHECK(cm_capture_allowed(0,"com.secret.extra","com.secret","",0)==1);
    CHECK(cm_capture_allowed(0,"com.safe","","com.other",0)==0);
    CHECK(cm_capture_allowed(0,"com.safe","","com.safe\ncom.other",0)==1);
    CHECK(cm_capture_allowed(0,"com.safe","","",1)==0);
    CHECK(cm_capture_allowed(0,"","","",0)==0);
    CHECK(cm_capture_allowed(0,"com.safe","com.safe","com.safe",0)==0);
    printf("PASS %d assertions: SQLite production core, synthetic fixtures, no clipboard; SQLite %s\n",assertions,sqlite3_libversion());
    return 0;
}
