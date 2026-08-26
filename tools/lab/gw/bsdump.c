#include <stdio.h>
#include <stdlib.h>
#include <bsreader.h>
int main(int argc, char** argv) {
    FILE* f = fopen(argv[1], "rb");
    if (!f) { perror("open"); return 1; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char* buf = malloc(n); fread(buf, 1, n, f); fclose(f);
    void* stream = bsnew(buf);
    const char* chunk; size_t size;
    while ((chunk = bsread(NULL, stream, &size)) != NULL) {
        fwrite(chunk, 1, size, stdout);
    }
    return 0;
}
