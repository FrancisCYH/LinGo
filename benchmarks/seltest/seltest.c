#define N 8

int a[N];
int b[N];
int c[N];
int d[N];
int out[N];

void kernel()
{
    int i;
    loop_begin();
    for (i = 0; i < N; i++) {
        // Keep the predicates as 1-bit values.
        _Bool x = (a[i] > 0);
        _Bool y = (b[i] > 0);
        _Bool z = (c[i] > 0);

        // First 1-bit MUX: r = x ? y : z  (select i1)
        _Bool r = x ? y : z;

        // Use r as the condition of a 32-bit MUX to avoid a standalone ZEXT.
        // This keeps r as a 1-bit signal feeding directly into another SEL.
        out[i] = r ? d[i] : 0;
    }
    loop_end();
}
