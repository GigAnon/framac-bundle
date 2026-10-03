/* MOCK Ivette: behaves like an Electron main process that starts a Frama-C server from PATH */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
int main(int argc, char **argv) {
  char *a[64] = {"frama-c", "-server-socket", "/tmp/mock-ivette.sock"}; int k = 3;
  for (int i = 1; i < argc && k < 62; i++) if (strcmp(argv[i], "--no-sandbox")) a[k++] = argv[i];
  a[k] = 0;
  fprintf(stderr, "mock ivette: sandbox flag %s\n", (argc > 1 && !strcmp(argv[1], "--no-sandbox")) ? "off" : "on");
  pid_t p = fork();
  if (!p) { execvp("frama-c", a); perror("execvp frama-c"); _exit(127); }
  sleep(120); return 0;
}
