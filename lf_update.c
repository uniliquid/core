#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <libpq-fe.h>

int main(int argc, char **argv) {

  // variable declarations:
  int err = 0;
  int i, count;
  char *conninfo;
  PGconn *db;
  PGresult *list;
  PGresult *status;

  // parse command line:
  if (argc == 0) return 1;
  if (argc == 1 || !strcmp(argv[1], "-h") || !strcmp(argv[1], "--help")) {
    FILE *out;
    out = argc == 1 ? stderr : stdout;
    fprintf(stdout, "\n");
    fprintf(stdout, "Usage: %s <conninfo>\n", argv[0]);
    fprintf(stdout, "\n");
    fprintf(stdout, "<conninfo> is specified by PostgreSQL's libpq,\n");
    fprintf(stdout, "see http://www.postgresql.org/docs/8.4/static/libpq-connect.html\n");
    fprintf(stdout, "\n");
    fprintf(stdout, "Example: %s dbname=liquid_feedback\n", argv[0]);
    fprintf(stdout, "\n");
    return argc == 1 ? 1 : 0;
  }
  {
    size_t len = 0;
    for (i=1; i<argc; i++) len += strlen(argv[i]) + 1;
    conninfo = malloc(len * sizeof(char));
    if (!conninfo) {
      fprintf(stderr, "Error: Could not allocate memory for conninfo string\n");
      return 1;
    }
    conninfo[0] = 0;
    for (i=1; i<argc; i++) {
      if (i>1) strcat(conninfo, " ");
      strcat(conninfo, argv[i]);
    }
  }

  // connect to database:
  db = PQconnectdb(conninfo);
  if (!db) {
    fprintf(stderr, "Error: Could not create database handle\n");
    return 1;
  }
  if (PQstatus(db) != CONNECTION_OK) {
    fprintf(stderr, "Could not open connection:\n%s", PQerrorMessage(db));
    return 1;
  }

  // delete expired sessions:
  status = PQexec(db, "DELETE FROM \"expired_session\"");
  if (!status) {
    fprintf(stderr, "Error in pqlib while sending SQL command deleting expired sessions\n");
    err = 1;
  } else if (
    PQresultStatus(status) != PGRES_COMMAND_OK &&
    PQresultStatus(status) != PGRES_TUPLES_OK
  ) {
    fprintf(stderr, "Error while executing SQL command deleting expired sessions:\n%s", PQresultErrorMessage(status));
    err = 1;
    PQclear(status);
  } else {
    PQclear(status);
  }
 
  // check member activity:
  status = PQexec(db, "SELECT \"check_activity\"()");
  if (!status) {
    fprintf(stderr, "Error in pqlib while sending SQL command checking member activity\n");
    err = 1;
  } else if (
    PQresultStatus(status) != PGRES_COMMAND_OK &&
    PQresultStatus(status) != PGRES_TUPLES_OK
  ) {
    fprintf(stderr, "Error while executing SQL command checking member activity:\n%s", PQresultErrorMessage(status));
    err = 1;
    PQclear(status);
  } else {
    PQclear(status);
  }

  // calculate member counts:
  status = PQexec(db, "SELECT \"calculate_member_counts\"()");
  if (!status) {
    fprintf(stderr, "Error in pqlib while sending SQL command calculating member counts\n");
    err = 1;
  } else if (
    PQresultStatus(status) != PGRES_COMMAND_OK &&
    PQresultStatus(status) != PGRES_TUPLES_OK
  ) {
    fprintf(stderr, "Error while executing SQL command calculating member counts:\n%s", PQresultErrorMessage(status));
    err = 1;
    PQclear(status);
  } else {
    PQclear(status);
  }

  // update open issues:
  list = PQexec(db, "SELECT \"id\" FROM \"open_issue\"");
  if (!list) {
    fprintf(stderr, "Error in pqlib while sending SQL command selecting open issues\n");
    err = 1;
  } else if (PQresultStatus(list) != PGRES_TUPLES_OK) {
    fprintf(stderr, "Error while executing SQL command selecting open issues:\n%s", PQresultErrorMessage(list));
    err = 1;
    PQclear(list);
  } else {
    count = PQntuples(list);
    for (i=0; i<count; i++) {
      const char *params[1];
      params[0] = PQgetvalue(list, i, 0);
      status = PQexecParams(
        db, "SELECT \"check_issue\"($1)", 1, NULL, params, NULL, NULL, 0
      );
      if (!status) {
        fprintf(stderr, "Error in pqlib while sending SQL command to call function \"check_issue\"(...):\n");
        err = 1;
      } else if (
        PQresultStatus(status) != PGRES_COMMAND_OK &&
        PQresultStatus(status) != PGRES_TUPLES_OK
      ) {
        fprintf(stderr, "Error while calling SQL function \"check_issue\"(...):\n%s", PQresultErrorMessage(status));
        err = 1;
        PQclear(status);
      } else {
        PQclear(status);
      }
    }
    PQclear(list);
  }

  // calculate ranks after voting is finished:
  // (NOTE: This is a seperate process to avoid long transactions with locking)
  list = PQexec(db, "SELECT \"id\" FROM \"issue_with_ranks_missing\"");
  if (!list) {
    fprintf(stderr, "Error in pqlib while sending SQL command selecting issues where ranks are missing\n");
    err = 1;
  } else if (PQresultStatus(list) != PGRES_TUPLES_OK) {
    fprintf(stderr, "Error while executing SQL command selecting issues where ranks are missing:\n%s", PQresultErrorMessage(list));
    err = 1;
    PQclear(list);
  } else {
    count = PQntuples(list);
    for (i=0; i<count; i++) {
      const char *params[1];
      params[0] = PQgetvalue(list, i, 0);
      status = PQexecParams(
        db, "SELECT \"calculate_ranks\"($1)", 1, NULL, params, NULL, NULL, 0
      );
      if (!status) {
        fprintf(stderr, "Error in pqlib while sending SQL command to call function \"calculate_ranks\"(...):\n");
        err = 1;
      } else if (
        PQresultStatus(status) != PGRES_COMMAND_OK &&
        PQresultStatus(status) != PGRES_TUPLES_OK
      ) {
        fprintf(stderr, "Error while calling SQL function \"calculate_ranks\"(...):\n%s", PQresultErrorMessage(status));
        err = 1;
        PQclear(status);
      } else {
        PQclear(status);
      }
    }
    PQclear(list);
  }

  // cleanup and exit
  PQfinish(db);
  return err;

}
