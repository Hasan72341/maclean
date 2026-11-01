#include <yara.h>
#include <yara/scan.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

typedef struct {
  const char* path;
} SCAN_CONTEXT;

static int handle_message(
    YR_SCAN_CONTEXT* context,
    int message,
    void* message_data,
    void* user_data) {
  if (message == CALLBACK_MSG_RULE_MATCHING) {
    YR_RULE* rule = (YR_RULE*) message_data;
    SCAN_CONTEXT* scan = (SCAN_CONTEXT*) user_data;
    printf("%s\t%s%c", rule->identifier, scan->path, '\0');
    fflush(stdout);
  }
  return CALLBACK_CONTINUE;
}

static void compiler_callback(
    int error_level,
    const char* file_name,
    int line_number,
    const YR_RULE* rule,
    const char* message,
    void* user_data) {
  fprintf(
      stderr,
      "%s:%d: %s\n",
      file_name != NULL ? file_name : "rules",
      line_number,
      message);
}

static const char* base_name(const char* path) {
  const char* slash = strrchr(path, '/');
  return slash != NULL ? slash + 1 : path;
}

static void extension_of(const char* name, char* output, size_t size) {
  const char* dot = strrchr(name, '.');
  if (dot == NULL || dot == name) {
    output[0] = '\0';
    return;
  }
  snprintf(output, size, "%s", dot + 1);
}

int main(int argc, char** argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s RULES FILELIST [MAXFILESIZE]\n", argv[0]);
    return 2;
  }

  long long max_file_size = argc > 3 ? atoll(argv[3]) : 0;

  if (yr_initialize() != ERROR_SUCCESS) {
    fprintf(stderr, "yara: initialize failed\n");
    return 1;
  }

  YR_COMPILER* compiler = NULL;
  if (yr_compiler_create(&compiler) != ERROR_SUCCESS) {
    fprintf(stderr, "yara: compiler creation failed\n");
    yr_finalize();
    return 1;
  }
  yr_compiler_set_callback(compiler, compiler_callback, NULL);

  const char* externals[] = {
      "file_path",
      "file_name",
      "file_extension",
      "filename",
      "filepath",
      "filetype",
      "extension",
      "owner",
      NULL,
  };
  for (int i = 0; externals[i] != NULL; i++) {
    yr_compiler_define_string_variable(compiler, externals[i], "");
  }

  FILE* rules_file = fopen(argv[1], "rb");
  if (rules_file == NULL) {
    fprintf(stderr, "yara: cannot open rules file %s\n", argv[1]);
    yr_compiler_destroy(compiler);
    yr_finalize();
    return 1;
  }
  int errors = yr_compiler_add_file(compiler, rules_file, NULL, argv[1]);
  fclose(rules_file);

  if (errors > 0) {
    fprintf(stderr, "yara: %d compile error(s)\n", errors);
    yr_compiler_destroy(compiler);
    yr_finalize();
    return 1;
  }

  YR_RULES* rules = NULL;
  if (yr_compiler_get_rules(compiler, &rules) != ERROR_SUCCESS || rules == NULL) {
    fprintf(stderr, "yara: could not finalize rules\n");
    yr_compiler_destroy(compiler);
    yr_finalize();
    return 1;
  }

  YR_SCANNER* scanner = NULL;
  if (yr_scanner_create(rules, &scanner) != ERROR_SUCCESS || scanner == NULL) {
    fprintf(stderr, "yara: could not create scanner\n");
    yr_rules_destroy(rules);
    yr_compiler_destroy(compiler);
    yr_finalize();
    return 1;
  }
  yr_scanner_set_flags(
      scanner,
      SCAN_FLAGS_FAST_MODE | SCAN_FLAGS_REPORT_RULES_MATCHING);

  FILE* list_file = fopen(argv[2], "rb");
  if (list_file == NULL) {
    fprintf(stderr, "yara: cannot open file list %s\n", argv[2]);
    yr_scanner_destroy(scanner);
    yr_rules_destroy(rules);
    yr_compiler_destroy(compiler);
    yr_finalize();
    return 1;
  }

  char* path = NULL;
  size_t capacity = 0;
  ssize_t length;
  SCAN_CONTEXT scan;

  while ((length = getdelim(&path, &capacity, '\0', list_file)) > 0) {
    if (length > 0 && path[length - 1] == '\0') {
      path[length - 1] = '\0';
    }
    if (path[0] == '\0') {
      continue;
    }

    struct stat info;
    if (stat(path, &info) != 0 || !S_ISREG(info.st_mode)) {
      continue;
    }
    if (max_file_size > 0 && info.st_size > max_file_size) {
      continue;
    }

    const char* name = base_name(path);
    char extension[64];
    extension_of(name, extension, sizeof(extension));

    scan.path = path;
    yr_scanner_set_callback(scanner, handle_message, &scan);
    yr_scanner_define_string_variable(scanner, "file_path", path);
    yr_scanner_define_string_variable(scanner, "file_name", name);
    yr_scanner_define_string_variable(scanner, "file_extension", extension);
    yr_scanner_define_string_variable(scanner, "filename", name);
    yr_scanner_define_string_variable(scanner, "filepath", path);
    yr_scanner_define_string_variable(scanner, "filetype", extension);
    yr_scanner_define_string_variable(scanner, "extension", extension);
    yr_scanner_define_string_variable(scanner, "owner", "");
    yr_scanner_scan_file(scanner, path);
  }

  free(path);
  fclose(list_file);
  yr_scanner_destroy(scanner);
  yr_rules_destroy(rules);
  yr_compiler_destroy(compiler);
  yr_finalize();
  return 0;
}
