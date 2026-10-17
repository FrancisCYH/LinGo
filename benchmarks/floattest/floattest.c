#define size 1024
float a[size];
float b[size];
float add_out[size];
float sub_out[size];

void kernel()
{
#ifdef CGRA_COMPILER
    loop_begin();
#endif
#pragma unroll 2
    for (int k = 0; k < size; k++) {
        add_out[k] = a[k] + b[k];
        sub_out[k] = a[k] - b[k];
    }
#ifdef CGRA_COMPILER
    loop_end();
#endif
}
