/* Optional. Installed setuid root only by scripts/raise.sh --chroot.
   The first thing it does after chroot is become the invoking user, then exec.
   usage: chroot-drop /absolute/dir -- command [args] */
#include <errno.h>
#include <grp.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char **argv) {
    uid_t ruid = getuid();
    gid_t rgid = getgid();
    struct stat st;

    if (geteuid() != 0) {
        fprintf(stderr, "chroot-drop: not installed setuid root. Run scripts/raise.sh --chroot\n");
        return 127;
    }
    if (argc < 4 || strcmp(argv[2], "--") != 0 || argv[1][0] != '/' || strchr(argv[1], '\n')) {
        fprintf(stderr, "usage: chroot-drop /absolute/dir -- command [args]\n");
        return 2;
    }
    if (lstat(argv[1], &st) != 0 || S_ISLNK(st.st_mode) || !S_ISDIR(st.st_mode)) {
        fprintf(stderr, "chroot-drop: %s is not a real directory\n", argv[1]);
        return 2;
    }
    if (chroot(argv[1]) != 0 || chdir("/") != 0) {
        perror("chroot-drop");
        return 1;
    }
    if (setgroups(0, NULL) != 0 || setgid(rgid) != 0 || setuid(ruid) != 0) {
        perror("chroot-drop");
        return 1;
    }
    if (geteuid() != ruid || getuid() != ruid || setuid(0) == 0) {
        fprintf(stderr, "chroot-drop: privileges were not dropped\n");
        return 1;
    }
    execvp(argv[3], argv + 3);
    perror("chroot-drop");
    return 127;
}
