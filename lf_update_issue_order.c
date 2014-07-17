#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <libpq-fe.h>
#include <search.h>

static int logging = 0;

static char *escapeLiteral(PGconn *conn, const char *str, size_t len) {
  // provides compatibility for PostgreSQL versions prior 9.0
  // in future: return PQescapeLiteral(conn, str, len);
  char *res;
  size_t res_len;
  res = malloc(2*len+3);
  if (!res) return NULL;
  res[0] = '\'';
  res_len = PQescapeStringConn(conn, res+1, str, len, NULL);
  res[res_len+1] = '\'';
  res[res_len+2] = 0;
  return res;
}

static void freemem(void *ptr) {
  // to be used for "escapeLiteral" function
  // provides compatibility for PostgreSQL versions prior 9.0
  // in future: PQfreemem(ptr);
  free(ptr);
}

// column numbers when querying "issue_supporter_in_admission_state" view in function main():
#define COL_MEMBER_ID 0
#define COL_WEIGHT    1
#define COL_ISSUE_ID  2

// data structure for a candidate (in this case an issue) to the proportional runoff system:
struct candidate {
  char *key;              // identifier of the candidate, which is the "issue_id" string
  double score_per_step;  // added score per step
  double score;           // current score of candidate; a score of 1.0 is needed to survive a round
  int seat;               // equals 0 for unseated candidates, or contains rank number
};

// compare two integers stored as strings (invocation like strcmp):
static int compare_id(char *id1, char *id2) {
  int ldiff;
  ldiff = strlen(id1) - strlen(id2);
  if (ldiff) return ldiff;
  else return strcmp(id1, id2);
}

// compare two candidates by their key (invocation like strcmp):
static int compare_candidate(struct candidate *c1, struct candidate *c2) {
  return compare_id(c1->key, c2->key);
}

// candidates are stored as global variables due to the constrained twalk() interface:
static int candidate_count;
static struct candidate *candidates;

// function to be passed to twalk() to store candidates ordered in candidates[] array:
static void register_candidate(char **candidate_key, VISIT visit, int level) {
  if (visit == postorder || visit == leaf) {
    struct candidate *candidate;
    candidate = candidates + (candidate_count++);
    candidate->key  = *candidate_key;
    candidate->seat = 0;
    if (logging) printf("Candidate #%i is issue #%s.\n", candidate_count, candidate->key);
  }
}

// performs a binary search in candidates[] array to lookup a candidate by its key (which is the issue_id):
static struct candidate *candidate_by_key(char *candidate_key) {
  struct candidate *candidate;
  struct candidate compare;
  compare.key = candidate_key;
  candidate = bsearch(&compare, candidates, candidate_count, sizeof(struct candidate), (void *)compare_candidate);
  if (!candidate) {
    fprintf(stderr, "Candidate not found (should not happen).\n");
    abort();
  }
  return candidate;
}

// ballot of the proportional runoff system, containing only one preference section:
struct ballot {
  int weight;  // if weight is greater than 1, then the ballot is counted multiple times
  int count;   // number of candidates
  struct candidate **candidates;  // all candidates equally preferred
};

// determine candidate, which is assigned the next seat (starting with the worst rank):
static struct candidate *loser(int round_number, struct ballot *ballots, int ballot_count) {
  int i, j;       // index variables for loops
  int remaining;  // remaining candidates to be seated
  // reset scores of all candidates:
  for (i=0; i<candidate_count; i++) {
    candidates[i].score = 0.0;
  }
  // calculate remaining candidates to be seated:
  remaining = candidate_count - round_number;
  // repeat following loop, as long as there is more than one remaining candidate:
  while (remaining > 1) {
    if (logging) printf("There are %i remaining candidates.\n", remaining);
    double scale;  // factor to be later multiplied with score_per_step:
    // reset score_per_step for all candidates:
    for (i=0; i<candidate_count; i++) {
      candidates[i].score_per_step = 0.0;
    }
    // calculate score_per_step for all candidates:
    for (i=0; i<ballot_count; i++) {
      int matches = 0;
      for (j=0; j<ballots[i].count; j++) {
        struct candidate *candidate;
        candidate = ballots[i].candidates[j];
        if (candidate->score < 1.0 && !candidate->seat) matches++;
      }
      if (matches) {
        double score_inc;
        score_inc = (double)ballots[i].weight / (double)matches;
        for (j=0; j<ballots[i].count; j++) {
          struct candidate *candidate;
          candidate = ballots[i].candidates[j];
          if (candidate->score < 1.0 && !candidate->seat) {
            candidate->score_per_step += score_inc;
          }
        }
      }
    }
    // calculate scale factor:
    scale = (double)0.0;  // 0.0 is used to indicate that there is no value yet
    for (i=0; i<candidate_count; i++) {
      double max_scale;
      if (candidates[i].score_per_step > 0.0) {
        max_scale = (1.0-candidates[i].score) / candidates[i].score_per_step;
        if (scale == 0.0 || max_scale <= scale) {
          scale = max_scale;
        }
      }
    }
    // add scale*score_per_step to each candidates score:
    for (i=0; i<candidate_count; i++) {
      int log_candidate = 0;
      if (logging && candidates[i].score < 1.0 && !candidates[i].seat) log_candidate = 1;
      if (log_candidate) printf("Score for issue #%s = %.4f+%.4f*%.4f", candidates[i].key, candidates[i].score, scale, candidates[i].score_per_step);
      if (candidates[i].score_per_step > 0.0) {
        double max_scale;
        max_scale = (1.0-candidates[i].score) / candidates[i].score_per_step;
        if (max_scale == scale) {
          // score of 1.0 should be reached, so we set score directly to avoid floating point errors:
          candidates[i].score = 1.0;
          remaining--;
        } else {
          candidates[i].score += scale * candidates[i].score_per_step;
          if (candidates[i].score >= 1.0) remaining--;
        }
      }
      if (log_candidate) {
        if (candidates[i].score >= 1.0) printf("=1\n");
        else printf("=%.4f\n", candidates[i].score);
      }
      // when there is only one candidate remaining, then break inner (and thus outer) loop:
      if (remaining <= 1) {
        break;
      }
    }
  }
  // return remaining candidate:
  for (i=0; i<candidate_count; i++) {
    if (candidates[i].score < 1.0 && !candidates[i].seat) return candidates+i;
  }
  // if there is no remaining candidate, then something went wrong:
  fprintf(stderr, "No remaining candidate (should not happen).");
  abort();
}

// write results to database:
static int write_ranks(PGconn *db, char *escaped_area_or_unit_id, char *mode) {
  PGresult *res;
  char *cmd;
  int i;
  res = PQexec(db, "BEGIN");
  if (!res) {
    fprintf(stderr, "Error in pqlib while sending SQL command to initiate issue order update.\n");
    return 1;
  } else if (
    PQresultStatus(res) != PGRES_COMMAND_OK &&
    PQresultStatus(res) != PGRES_TUPLES_OK
  ) {
    fprintf(stderr, "Error while executing SQL command to initiate issue order update:\n%s", PQresultErrorMessage(res));
    PQclear(res);
    return 1;
  } else {
    PQclear(res);
  }
  for (i=0; i<candidate_count; i++) {
    char *escaped_issue_id;
    escaped_issue_id = escapeLiteral(db, candidates[i].key, strlen(candidates[i].key));
    if (!escaped_issue_id) {
      fprintf(stderr, "Could not escape literal in memory.\n");
      abort();
    }
    if (asprintf(&cmd, "UPDATE \"issue_order_in_admission_state\" SET \"order_in_%s\" = %i WHERE \"id\" = %s", mode, candidates[i].seat, escaped_issue_id) < 0) {
      fprintf(stderr, "Could not prepare query string in memory.\n");
      abort();
    }
    freemem(escaped_issue_id);
    res = PQexec(db, cmd);
    free(cmd);
    if (!res) {
      fprintf(stderr, "Error in pqlib while sending SQL command to update issue order.\n");
    } else if (
      PQresultStatus(res) != PGRES_COMMAND_OK &&
      PQresultStatus(res) != PGRES_TUPLES_OK
    ) {
      fprintf(stderr, "Error while executing SQL command to update issue order:\n%s", PQresultErrorMessage(res));
      PQclear(res);
    } else {
      PQclear(res);
      continue;
    }
    res = PQexec(db, "ROLLBACK");
    if (res) PQclear(res);
    return 1;
  }
  res = PQexec(db, "COMMIT");
  if (!res) {
    fprintf(stderr, "Error in pqlib while sending SQL command to commit transaction.\n");
    return 1;
  } else if (
    PQresultStatus(res) != PGRES_COMMAND_OK &&
    PQresultStatus(res) != PGRES_TUPLES_OK
  ) {
    fprintf(stderr, "Error while executing SQL command to commit transaction:\n%s", PQresultErrorMessage(res));
    PQclear(res);
    return 1;
  } else {
    PQclear(res);
  }
  return 0;
}

// calculate ordering of issues in admission state for an area and call write_ranks() to write it to database:
static int process_area_or_unit(PGconn *db, PGresult *res, char *escaped_area_or_unit_id, char *mode) {
  int err;                 // variable to store an error condition (0 = success)
  int ballot_count = 1;    // number of ballots, must be initiatized to 1, due to loop below
  struct ballot *ballots;  // data structure containing the ballots
  int i;                   // index variable for loops
  // create candidates[] and ballots[] arrays:
  {
    void *candidate_tree = NULL;  // temporary structure to create a sorted unique list of all candidate keys
    int tuple_count;              // number of tuples returned from the database
    char *old_member_id = NULL;   // old member_id to be able to detect a new ballot in loops
    struct ballot *ballot;        // pointer to current ballot
    int candidates_in_ballot = 0; // number of candidates in ballot
    // reset candidate count:
    candidate_count = 0;
    // determine number of tuples:
    tuple_count = PQntuples(res);
    // trivial case, when there are no tuples:
    if (!tuple_count) {
      // write results to database:
      if (logging) printf("No supporters for any issue. Writing ranks to database.\n");
      err = write_ranks(db, escaped_area_or_unit_id, mode);
      if (logging) printf("Done.\n");
      return 0;
    }
    // calculate ballot_count and generate set of candidate keys (issue_id is used as key):
    for (i=0; i<tuple_count; i++) {
      char *member_id, *issue_id;
      member_id = PQgetvalue(res, i, COL_MEMBER_ID);
      issue_id = PQgetvalue(res, i, COL_ISSUE_ID);
      if (!candidate_tree || !tfind(issue_id, &candidate_tree, (void *)compare_id)) {
        candidate_count++;
        if (!tsearch(issue_id, &candidate_tree, (void *)compare_id)) {
          fprintf(stderr, "Insufficient memory while inserting into candidate tree.\n");
          abort();
        }
      }
      if (old_member_id && strcmp(old_member_id, member_id)) ballot_count++;
      old_member_id = member_id;
    }
    // allocate memory for candidates[] array:
    candidates = malloc(candidate_count * sizeof(struct candidate));
    if (!candidates) {
      fprintf(stderr, "Insufficient memory while creating candidate list.\n");
      abort();
    }
    // transform tree of candidate keys into sorted array:
    candidate_count = 0;  // needed by register_candidate()
    twalk(candidate_tree, (void *)register_candidate);
    // free memory of tree structure (tdestroy() is not available on all platforms):
    while (candidate_tree) tdelete(*(void **)candidate_tree, &candidate_tree, (void *)compare_id);
    // allocate memory for ballots[] array:
    ballots = calloc(ballot_count, sizeof(struct ballot));
    if (!ballots) {
      fprintf(stderr, "Insufficient memory while creating ballot list.\n");
      abort();
    }
    // set ballot weights, determine ballot section sizes, and verify preference values:
    ballot = ballots;
    old_member_id = NULL;
    for (i=0; i<tuple_count; i++) {
      char *member_id;
      int weight;
      member_id = PQgetvalue(res, i, COL_MEMBER_ID);
      weight = (int)strtol(PQgetvalue(res, i, COL_WEIGHT), (char **)NULL, 10);
      if (weight <= 0) {
        fprintf(stderr, "Unexpected weight value.\n");
        free(ballots);
        free(candidates);
        return 1;
      }
      if (old_member_id && strcmp(old_member_id, member_id)) ballot++;
      ballot->weight = weight;
      ballot->count++;
      old_member_id = member_id;
    }
    // allocate memory for ballot sections:
    for (i=0; i<ballot_count; i++) {
      if (ballots[i].count) {
        ballots[i].candidates = malloc(ballots[i].count * sizeof(struct candidate *));
        if (!ballots[i].candidates) {
          fprintf(stderr, "Insufficient memory while creating ballot section.\n");
          abort();
        }
      }
    }
    // fill ballot sections with candidate references:
    old_member_id = NULL;
    ballot = ballots;
    for (i=0; i<tuple_count; i++) {
      char *member_id, *issue_id;
      member_id = PQgetvalue(res, i, COL_MEMBER_ID);
      issue_id = PQgetvalue(res, i, COL_ISSUE_ID);
      if (old_member_id && strcmp(old_member_id, member_id)) {
        ballot++;
        candidates_in_ballot = 0;
      }
      ballot->candidates[candidates_in_ballot++] = candidate_by_key(issue_id);
      old_member_id = member_id;
    }
    // print ballots, if logging is enabled:
    if (logging) {
      for (i=0; i<ballot_count; i++) {
        int j;
        printf("Ballot #%i: ", i+1);
        for (j=0; j<ballots[i].count; j++) {
          if (!j) printf("issues ");
          else printf(", ");
          printf("#%s", ballots[i].candidates[j]->key);
        }
        // if (!j) printf("empty");  // should not happen
        printf(".\n");
      }
    }
  }

  // calculate ranks based on constructed data structures:
  for (i=0; i<candidate_count; i++) {
    struct candidate *candidate = loser(i, ballots, ballot_count);
    candidate->seat = candidate_count - i;
    if (logging) printf("Assigning rank #%i to issue #%s.\n", candidate_count-i, candidate->key);
  }

  // free ballots[] array:
  for (i=0; i<ballot_count; i++) {
    // if (ballots[i].count) {  // count should not be zero
      free(ballots[i].candidates);
    // }
  }
  free(ballots);

  // write results to database:
  if (logging) printf("Writing ranks to database.\n");
  err = write_ranks(db, escaped_area_or_unit_id, mode);
  if (logging) printf("Done.\n");

  // free candidates[] array:
  free(candidates);

  // return error code of write_ranks() call
  return err;
}

int main(int argc, char **argv) {

  // variable declarations:
  int err = 0;
  int i, count;
  char *conninfo;
  PGconn *db;
  PGresult *res;

  // parse command line:
  if (argc == 0) return 1;
  if (argc == 1 || !strcmp(argv[1], "-h") || !strcmp(argv[1], "--help")) {
    FILE *out;
    out = argc == 1 ? stderr : stdout;
    fprintf(out, "\n");
    fprintf(out, "Usage: %s [-v|--verbose] <conninfo>\n", argv[0]);
    fprintf(out, "\n");
    fprintf(out, "<conninfo> is specified by PostgreSQL's libpq,\n");
    fprintf(out, "see http://www.postgresql.org/docs/9.1/static/libpq-connect.html\n");
    fprintf(out, "\n");
    fprintf(out, "Example: %s dbname=liquid_feedback\n", argv[0]);
    fprintf(out, "\n");
    return argc == 1 ? 1 : 0;
  }
  {
    size_t len = 0;
    int argb = 1;
    if (
      argc >= 2 &&
      (!strcmp(argv[1], "-v") || !strcmp(argv[1], "--verbose"))
    ) {
      argb = 2;
      logging = 1;
    }
    for (i=argb; i<argc; i++) len += strlen(argv[i]) + 1;
    conninfo = malloc(len * sizeof(char));
    if (!conninfo) {
      fprintf(stderr, "Error: Could not allocate memory for conninfo string.\n");
      abort();
    }
    conninfo[0] = 0;
    for (i=argb; i<argc; i++) {
      if (i>argb) strcat(conninfo, " ");
      strcat(conninfo, argv[i]);
    }
  }

  // connect to database:
  db = PQconnectdb(conninfo);
  if (!db) {
    fprintf(stderr, "Error: Could not create database handle.\n");
    return 1;
  }
  if (PQstatus(db) != CONNECTION_OK) {
    fprintf(stderr, "Could not open connection:\n%s", PQerrorMessage(db));
    return 1;
  }

  // create missing "issue_order_in_admission_state" entries for issues
  res = PQexec(db, "INSERT INTO \"issue_order_in_admission_state\" (\"id\") SELECT \"issue\".\"id\" FROM \"issue\" NATURAL LEFT JOIN \"issue_order_in_admission_state\" WHERE \"issue\".\"state\" = 'admission'::\"issue_state\" AND \"issue_order_in_admission_state\".\"id\" ISNULL");
  if (!res) {
    fprintf(stderr, "Error in pqlib while sending SQL command creating new issue order entries.\n");
    err = 1;
  } else if (
    PQresultStatus(res) != PGRES_COMMAND_OK &&
    PQresultStatus(res) != PGRES_TUPLES_OK
  ) {
    fprintf(stderr, "Error while executing SQL command creating new issue order entries:\n%s", PQresultErrorMessage(res));
    err = 1;
    PQclear(res);
  } else {
    if (logging) printf("Created %s new issue order entries.\n", PQcmdTuples(res));
    PQclear(res);
  }

  // go through areas:
  res = PQexec(db, "SELECT \"id\" FROM \"area\"");
  if (!res) {
    fprintf(stderr, "Error in pqlib while sending SQL command selecting areas to process.\n");
    err = 1;
  } else if (PQresultStatus(res) != PGRES_TUPLES_OK) {
    fprintf(stderr, "Error while executing SQL command selecting areas to process:\n%s", PQresultErrorMessage(res));
    err = 1;
    PQclear(res);
  } else if (PQnfields(res) < 1) {
    fprintf(stderr, "Too few columns returned by SQL command selecting areas to process.\n");
    err = 1;
    PQclear(res);
  } else {
    count = PQntuples(res);
    if (logging) printf("Number of areas to process: %i\n", count);
    for (i=0; i<count; i++) {
      char *area_id, *escaped_area_id;
      char *cmd;
      PGresult *res2;
      area_id = PQgetvalue(res, i, 0);
      if (logging) printf("Processing area #%s:\n", area_id);
      escaped_area_id = escapeLiteral(db, area_id, strlen(area_id));
      if (!escaped_area_id) {
        fprintf(stderr, "Could not escape literal in memory.\n");
        abort();
      }
      if (asprintf(&cmd, "SELECT \"member_id\", \"weight\", \"issue_id\" FROM \"issue_supporter_in_admission_state\" WHERE \"area_id\" = %s ORDER BY \"member_id\"", escaped_area_id) < 0) {
        fprintf(stderr, "Could not prepare query string in memory.\n");
        abort();
      }
      res2 = PQexec(db, cmd);
      free(cmd);
      if (!res2) {
        fprintf(stderr, "Error in pqlib while sending SQL command selecting issue supporter in admission state.\n");
        err = 1;
      } else if (PQresultStatus(res2) != PGRES_TUPLES_OK) {
        fprintf(stderr, "Error while executing SQL command selecting issue supporter in admission state:\n%s", PQresultErrorMessage(res));
        err = 1;
        PQclear(res2);
      } else if (PQnfields(res2) < 3) {
        fprintf(stderr, "Too few columns returned by SQL command selecting issue supporter in admission state.\n");
        err = 1;
        PQclear(res2);
      } else {
        if (process_area_or_unit(db, res2, escaped_area_id, "area")) err = 1;
        PQclear(res2);
      }
      freemem(escaped_area_id);
    }
    PQclear(res);
  }

  // go through units:
  res = PQexec(db, "SELECT \"id\" FROM \"unit\"");
  if (!res) {
    fprintf(stderr, "Error in pqlib while sending SQL command selecting units to process.\n");
    err = 1;
  } else if (PQresultStatus(res) != PGRES_TUPLES_OK) {
    fprintf(stderr, "Error while executing SQL command selecting units to process:\n%s", PQresultErrorMessage(res));
    err = 1;
    PQclear(res);
  } else if (PQnfields(res) < 1) {
    fprintf(stderr, "Too few columns returned by SQL command selecting units to process.\n");
    err = 1;
    PQclear(res);
  } else {
    count = PQntuples(res);
    if (logging) printf("Number of units to process: %i\n", count);
    for (i=0; i<count; i++) {
      char *unit_id, *escaped_unit_id;
      char *cmd;
      PGresult *res2;
      unit_id = PQgetvalue(res, i, 0);
      if (logging) printf("Processing unit #%s:\n", unit_id);
      escaped_unit_id = escapeLiteral(db, unit_id, strlen(unit_id));
      if (!escaped_unit_id) {
        fprintf(stderr, "Could not escape literal in memory.\n");
        abort();
      }
      if (asprintf(&cmd, "SELECT \"member_id\", \"weight\", \"issue_id\" FROM \"issue_supporter_in_admission_state\" WHERE \"unit_id\" = %s ORDER BY \"member_id\"", escaped_unit_id) < 0) {
        fprintf(stderr, "Could not prepare query string in memory.\n");
        abort();
      }
      res2 = PQexec(db, cmd);
      free(cmd);
      if (!res2) {
        fprintf(stderr, "Error in pqlib while sending SQL command selecting issue supporter in admission state.\n");
        err = 1;
      } else if (PQresultStatus(res2) != PGRES_TUPLES_OK) {
        fprintf(stderr, "Error while executing SQL command selecting issue supporter in admission state:\n%s", PQresultErrorMessage(res));
        err = 1;
        PQclear(res2);
      } else if (PQnfields(res2) < 3) {
        fprintf(stderr, "Too few columns returned by SQL command selecting issue supporter in admission state.\n");
        err = 1;
        PQclear(res2);
      } else {
        if (process_area_or_unit(db, res2, escaped_unit_id, "unit")) err = 1;
        PQclear(res2);
      }
      freemem(escaped_unit_id);
    }
    PQclear(res);
  }

  // clean-up entries of deleted issues
  res = PQexec(db, "DELETE FROM \"issue_order_in_admission_state\" USING \"issue_order_in_admission_state\" AS \"self\" NATURAL LEFT JOIN \"issue\" WHERE \"issue_order_in_admission_state\".\"id\" = \"self\".\"id\" AND (\"issue\".\"id\" ISNULL OR \"issue\".\"state\" != 'admission'::\"issue_state\")");
  if (!res) {
    fprintf(stderr, "Error in pqlib while sending SQL command deleting ordering data of deleted issues.\n");
    err = 1;
  } else if (
    PQresultStatus(res) != PGRES_COMMAND_OK &&
    PQresultStatus(res) != PGRES_TUPLES_OK
  ) {
    fprintf(stderr, "Error while executing SQL command deleting ordering data of deleted issues:\n%s", PQresultErrorMessage(res));
    err = 1;
    PQclear(res);
  } else {
    if (logging) printf("Cleaned up ordering data of %s deleted issues.\n", PQcmdTuples(res));
    PQclear(res);
  }

  // cleanup and exit:
  PQfinish(db);
  if (!err) {
    if (logging) printf("Successfully terminated.\n");
  } else {
    fprintf(stderr, "Exiting with error code %i.\n", err);
  }
  return err;

}
