#!/bin/bash

# Run a standard suite of tests and create the outputs.
STD_SAMP=8388608
STD_CHAN=2048
STD_NANT=6

for s in 4194304 8388608 16777216
do
    echo samples = $s
    ./benchmark_gxkernel -c ${STD_CHAN} -a ${STD_NANT} -s $s -j nant${STD_NANT}_chan${STD_CHAN}_samp${s}.json
done

for c in 512 1024 2048 4096 8192 16384 32768
do
    echo chans = $s
    ./benchmark_gxkernel -c $c -a ${STD_NANT} -s ${STD_SAMP} -j nant${STD_NANT}_chan${c}_samp${STD_SAMP}.json
done

for n in 4 5 6 7 8 9 10
do
    echo ants = $n
    ./benchmark_gxkernel -c ${STD_CHAN} -a $n -s ${STD_SAMP} -j nant${n}_chan${STD_CHAN}_samp${STD_SAMP}.json
done