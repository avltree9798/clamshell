// Host driver for generate.sh: runs the self-test natively and prints the results.
#include <stdint.h>
#include <stdio.h>
extern uint32_t results[64];
int guest_main(void);
int main(void) {
    int n = guest_main();
    for (int i = 0; i < n; i++) printf("0x%08X,%s", results[i], i % 6 == 5 ? "\n" : " ");
    printf("\n");
    return 0;
}
