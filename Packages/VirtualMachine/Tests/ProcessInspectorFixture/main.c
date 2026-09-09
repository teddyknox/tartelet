// A harmless non-platform process: macOS hides environment variables of platform binaries such
// as /bin/sleep. This fixture lets the inspector verify argv and TART_HOME as it does for Tart.
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "hold") == 0 && open(argv[2], O_RDONLY) < 0) return 2;
    sleep(30);
    return 0;
}
