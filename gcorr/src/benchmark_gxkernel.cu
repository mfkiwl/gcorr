#include <stdio.h>
#include <stdlib.h>
#include <strings.h>
#include <argp.h>
#include <complex.h>
#include <cuComplex.h>
#include <npp.h>
#include <cuda.h>
#include <curand.h>
#include <cufft.h>
#include "gxkernel.h"

/*
 * Code to test the kernels in the gxkernel.cu.
 */

void preLaunchCheck() {
  cudaError_t error;

  error = cudaGetLastError();
  
  if (error != cudaSuccess) {
    fprintf(stderr, "Error: Previous CUDA failure: \"%s\". Exiting\n",
	    cudaGetErrorString(error));
    exit(EXIT_FAILURE);
  }
}

void postLaunchCheck() {
  cudaError_t error;

  error = cudaGetLastError();
  
  if (error != cudaSuccess) {
    fprintf(stderr, "Error: Failure Launching kernel: \"%s\". Exiting\n",
	    cudaGetErrorString(error));
    exit(EXIT_FAILURE);
  }
}

struct timerCollection {
  cudaEvent_t startTime;
  cudaEvent_t endTime;
  int nTimers;
  char **timerNames;
  int *numIterations;
  float **timerResults;
  float **timerStatistics;
  int *timerCalculated;
  int currentTimer;
};

void timerInitialise(struct timerCollection *tc) {
  // Set up the structure correctly
  cudaEventCreate(&(tc->startTime));
  cudaEventCreate(&(tc->endTime));
  tc->nTimers = 0;
  tc->timerNames = NULL;
  tc->numIterations = NULL;
  tc->timerResults = NULL;
  tc->timerStatistics = NULL;
  tc->timerCalculated = NULL;
  tc->currentTimer = -1;
}

void timerAdd(struct timerCollection *tc, const char* timerName) {
  // Add a timer to the collector.
  tc->nTimers ++;
  tc->timerNames = (char **)realloc(tc->timerNames, tc->nTimers * sizeof(char *));
  tc->timerNames[tc->nTimers - 1] = (char *)malloc(256 * sizeof(char));
  strcpy(tc->timerNames[tc->nTimers - 1], timerName);
  tc->numIterations = (int *)realloc(tc->numIterations, tc->nTimers * sizeof(int));
  tc->numIterations[tc->nTimers - 1] = 0;
  tc->timerResults = (float **)realloc(tc->timerResults, tc->nTimers * sizeof(float *));
  tc->timerResults[tc->nTimers - 1] = NULL;
  tc->timerStatistics = (float **)realloc(tc->timerStatistics, tc->nTimers * sizeof(float *));
  //tc->timerStatistics[tc->nTimers - 1] = (float *)malloc(3 * sizeof(float));
  tc->timerCalculated = (int *)realloc(tc->timerCalculated, tc->nTimers * sizeof(int));
  tc->timerCalculated[tc->nTimers - 1] = 0;
}

int timerStart(struct timerCollection *tc, const char *timerName) {
  // Start the timer.
  // Return immediately if a timer has already been started.
  if (tc->currentTimer != -1) {
    return -1;
  }
  
  int i;
  for (i = 0; i < tc->nTimers; i++) {
    if (strcmp(tc->timerNames[i], timerName) == 0) {
      tc->currentTimer = i;
      break;
    }
  }

  if (tc->currentTimer >= 0) {
    tc->timerCalculated[tc->currentTimer] = 0;
    preLaunchCheck();
    cudaEventRecord(tc->startTime, 0);
    return 0;
  }

  return -2;
}

float timerEnd(struct timerCollection *tc) {
  // Stop the running timer.
  // Return immediately if no timer has been started.
  if (tc->currentTimer == -1) {
    return 0.0;
  }

  // Keep a copy of the current timer.
  int ct = tc->currentTimer;
  
  // Stop the timer.
  cudaEventRecord(tc->endTime, 0);
  cudaEventSynchronize(tc->endTime);
  postLaunchCheck();

  // Add an iteration to the right place.
  tc->numIterations[ct] += 1;
  int nint = tc->numIterations[ct];
  tc->timerResults[ct] = (float *)realloc(tc->timerResults[ct],
					  nint * sizeof(float));
  cudaEventElapsedTime(&(tc->timerResults[ct][nint - 1]),
		       tc->startTime, tc->endTime);
  

  // Reset the current timer.
  tc->currentTimer = -1;
  
  // Return the elapsed time.
  return tc->timerResults[ct][nint];
}

void time_stats(float *timearray, int ntime, float *average, float *min, float *max) {
  int i = 0;
  *average = 0.0;
  for (i = 1; i < ntime; i++) {
    *average += timearray[i];
    if (i == 1) {
      *min = timearray[i];
      *max = timearray[i];
    } else {
      *min = (timearray[i] < *min) ? timearray[i] : *min;
      *max = (timearray[i] > *max) ? timearray[i] : *max;
    }
  }

  if ((ntime - 1) > 0) {
    *average /= (float)(ntime - 1);
  }
  return;
}

void time_stats_single(float *timearray, int ntime, float **output) {
  int i = 0;
  *output = (float *)malloc(3 * sizeof(float));

  *output[0] = 0.0;
  for (i = 1; i < ntime; i++) {
    *output[0] += timearray[i];
    if (i == 1) {
      *output[1] = timearray[i];
      *output[2] = timearray[i];
    } else {
      *output[1] = (timearray[i] < *output[1]) ? timearray[i] : *output[1];
      *output[2] = (timearray[i] > *output[2]) ? timearray[i] : *output[2];
    }
  }

  if ((ntime - 1) > 0) {
    *output[0] /= (float)(ntime - 1);
  }

  return;
			   
}

void timerPrintStatistics(struct timerCollection *tc, const char *timerName, float implied_time) {
  // Calculate statistics if required and print the output.
  int i, c = -1;

  // Find the appropriate timer.
  for (i = 0; i < tc->nTimers; i++) {
    if (strcmp(tc->timerNames[i], timerName) == 0) {
      c = i;
      break;
    }
  }

  if (c >= 0) {
    if (tc->timerCalculated[c] == 0) {
      // Calculate the statistics.
      (void)time_stats_single(tc->timerResults[c], tc->numIterations[c],
			      &(tc->timerStatistics[c]));
      tc->timerCalculated[c] = 1;
    }
    printf("\n==== TIMER: %s ====\n", tc->timerNames[c]);
    printf("Iterations | Average time |  Min time   |  Max time   | Data time  | Speed up  |\n");
    printf("%5d      | %8.3f ms  | %8.3f ms | %8.3f ms | %8.3f s | %8.3f  |\n",
	   (tc->numIterations[c] - 1), (tc->timerStatistics[c][0]),
	   (tc->timerStatistics[c][1]), (tc->timerStatistics[c][2]),
	   implied_time, ((implied_time * 1e3) / tc->timerStatistics[c][0]));
  }
}

const char *argp_program_version = "benchmark_gxkernel 1.0";
static char doc[] = "benchmark_gxkernel -- testing performance of various kernels";
static char args_doc[] = "";

/* Our command line options */
static struct argp_option options[] = {
  { "loops", 'n', "NLOOPS", 0, "run each performance test NLOOPS times" },
  { "threads", 't', "NTHREADS", 0, "run with NTHREADS threads on each test" },
  { "antennas", 'a', "NANTENNAS", 0, "assume NANTENNAS antennas when required" },
  { "channels", 'c', "NCHANNELS", 0, "assume NCHANNELS frequency channels when required" },
  { "samples", 's', "NSAMPLES", 0, "assume NSAMPLES when unpacking" },
  { "bandwidth", 'b', "BANDWIDTH", 0, "the bandwidth in Hz" },
  { "verbose", 'v', 0, 0, "output more" },
  { "bits", 'B', "NBITS", 0, "number of bits assumed in the data" },
  { "complex", 'I', 0, 0, "the data input is complex sampled" },
  { 0 }
};

struct arguments {
  int nloops;
  int nthreads;
  int nantennas;
  int nchannels;
  int nsamples;
  int bandwidth;
  int verbose;
  int nbits;
  int complexdata;
};

/* The option parser */
static error_t parse_opt(int key, char *arg, struct argp_state *state) {
  struct arguments *arguments = (struct arguments *)state->input;

  switch (key) {
  case 'n':
    arguments->nloops = atoi(arg);
    break;
  case 't':
    arguments->nthreads = atoi(arg);
    break;
  case 'a':
    arguments->nantennas = atoi(arg);
    break;
  case 'c':
    arguments->nchannels = atoi(arg);
    break;
  case 's':
    arguments->nsamples = atoi(arg);
    break;
  case 'b':
    arguments->bandwidth = atoi(arg);
    break;
  case 'v':
    arguments->verbose = 1;
    break;
  case 'B':
    arguments->nbits = atoi(arg);
    break;
  case 'C':
    arguments->complexdata = 1;
    break;
  }
  return 0;
}

/* The argp parser */
static struct argp argp = { options, parse_opt, args_doc, doc };


int main(int argc, char *argv[]) {
  
  /* Default argument values first. */
  struct arguments arguments;
  arguments.nloops = 100;
  arguments.nthreads = 512;
  arguments.nantennas = 6;
  arguments.nchannels = 2048;
  arguments.nsamples = 1<<23;
  arguments.bandwidth = 64e6;
  arguments.verbose = 0;
  arguments.nbits = 2;
  arguments.complexdata = 0;
  int npolarisations = 2;
  curandGenerator_t gen;
  
  argp_parse(&argp, argc, argv, 0, 0, &arguments);

  // Always discard the first trial.
  arguments.nloops += 1;

  // Calculate the samplegranularity
  int samplegranularity = 8 / (arguments.nbits * npolarisations);
  if (samplegranularity < 1)
  {
    samplegranularity = 1;
  }
  
  // Calculate the number of FFTs
  int fftchannels = arguments.nchannels * ((arguments.complexdata == 1) ? 1 : 2);
  int numffts = arguments.nsamples / fftchannels;
  printf("fftchannels = %d , numffts is %d\n", fftchannels, numffts);
  if (numffts % 8) {
    printf("Unable to proceed, numffts must be divisible by 8!\n");
    exit(0);
  }

  printf("BENCHMARK PROGRAM STARTS\n\n");

  // Our collection of timers.
  struct timerCollection timers;
  timerInitialise(&timers);
  float timerResult;
  
  /*
   * This benchmarks unpacker kernels.
   */
  cuComplex **unpacked = new cuComplex*[arguments.nantennas * npolarisations];
  cuComplex **unpackedData, *unpackedData2;
  int8_t **packedData, **packedData8;
  int32_t *sampleShift;
  float *dtime_unpack=NULL, *dtime_unpack2=NULL, *dtime_unpack3=NULL, *dtime_unpack4=NULL;
  float averagetime_unpack = 0.0, mintime_unpack = 0.0, maxtime_unpack = 0.0;
  float averagetime_unpack2 = 0.0, mintime_unpack2 = 0.0, maxtime_unpack2 = 0.0;
  float averagetime_unpack3 = 0.0, mintime_unpack3 = 0.0, maxtime_unpack3 = 0.0;
  float averagetime_unpack4 = 0.0, mintime_unpack4 = 0.0, maxtime_unpack4 = 0.0;
  float implied_time;
  cudaEvent_t start_test_unpack, end_test_unpack;
  cudaEvent_t start_test_unpack2, end_test_unpack2;
  cudaEvent_t start_test_unpack3, end_test_unpack3;
  cudaEvent_t start_test_unpack4, end_test_unpack4;
  dim3 FringeSetblocks;
  double *gpuDelays, **delays, *antfileoffsets;
  double lo, sampletime;
  // TODO
  float *rotationPhaseInfo, *fractionalSampleDelays;

  dtime_unpack = (float *)malloc(arguments.nloops * sizeof(float));
  dtime_unpack2 = (float *)malloc(arguments.nloops * sizeof(float));
  dtime_unpack3 = (float *)malloc(arguments.nloops * sizeof(float));
  dtime_unpack4 = (float *)malloc(arguments.nloops * sizeof(float));
  int i, j, unpackBlocks;

  FringeSetblocks = dim3(8, arguments.nantennas);
  
  // Allocate the memory.
  int packedBytes = arguments.nsamples * 2 * npolarisations / 8;
  int packedBytes8 = packedBytes * 4;
  packedData = new int8_t*[arguments.nantennas];
  packedData8 = new int8_t*[arguments.nantennas];
  for (i = 0; i < arguments.nantennas; i++) {
    gpuErrchk(cudaMalloc(&packedData[i], packedBytes));
    gpuErrchk(cudaMalloc(&packedData8[i], packedBytes8));
  }
  for (i = 0; i < arguments.nantennas * npolarisations; i++) {
    gpuErrchk(cudaMalloc(&unpacked[i], arguments.nsamples * sizeof(cuComplex)));
  }
  gpuErrchk(cudaMalloc(&unpackedData, arguments.nantennas * npolarisations * sizeof(cuComplex*)));
  gpuErrchk(cudaMemcpy(unpackedData, unpacked, arguments.nantennas * npolarisations * sizeof(cuComplex*), cudaMemcpyHostToDevice));
  gpuErrchk(cudaMalloc(&unpackedData2, arguments.nantennas * npolarisations * arguments.nsamples * sizeof(cuComplex)));

  /* Allocate memory for the sample shifts vector */
  gpuErrchk(cudaMalloc(&sampleShift, arguments.nantennas * numffts * sizeof(int)));
  gpuErrchk(cudaMemset(sampleShift, 0, arguments.nantennas * numffts * sizeof(int)));
  gpuErrchk(cudaMalloc(&rotationPhaseInfo, arguments.nantennas * numffts * 2 * sizeof(float)));
  gpuErrchk(cudaMalloc(&fractionalSampleDelays, arguments.nantennas * numffts * 2 * sizeof(float)));
  
  // Copy the delays to the GPU.
  gpuErrchk(cudaMalloc(&gpuDelays, arguments.nantennas * 4 * sizeof(double)));
  delays = new double*[arguments.nantennas];
  antfileoffsets = new double[arguments.nantennas];
  srand(time(NULL));
  for (i = 0; i < arguments.nantennas; i++) {
    delays[i] = new double[3];
    for (j = 0; j < 3; j++) {
      delays[i][j] = (double)rand();
    }
    antfileoffsets[i] = (double)rand();
  }
  for (i = 0; i < arguments.nantennas; i++) {
    gpuErrchk(cudaMemcpy(&(gpuDelays[i * 4]), delays[i], 3 * sizeof(double), cudaMemcpyHostToDevice));
    gpuErrchk(cudaMemcpy(&(gpuDelays[i * 4 + 3]), &(antfileoffsets[i]), sizeof(double), cudaMemcpyHostToDevice));
  }

  // Generate some random numbers, and some not so random.
  lo = (double)rand();
  sampletime = (arguments.complexdata == 1) ? (1.0 / arguments.bandwidth) : (1.0 / (2 * arguments.bandwidth));
  
  
  unpackBlocks = arguments.nsamples / npolarisations / arguments.nthreads;
  printf("Each unpacking test will run with %d threads, %d blocks\n", arguments.nthreads, unpackBlocks);
  printf("  nsamples = %d\n", arguments.nsamples);
  printf("  nantennas = %d\n", arguments.nantennas);
  
  cudaEventCreate(&start_test_unpack);
  cudaEventCreate(&end_test_unpack);
  cudaEventCreate(&start_test_unpack2);
  cudaEventCreate(&end_test_unpack2);
  cudaEventCreate(&start_test_unpack3);
  cudaEventCreate(&end_test_unpack3);
  cudaEventCreate(&start_test_unpack4);
  cudaEventCreate(&end_test_unpack4);
  // Generate some random data.
  curandCreateGenerator(&gen, CURAND_RNG_PSEUDO_DEFAULT);
  curandSetPseudoRandomGeneratorSeed(gen, time(NULL));
  for (i = 0; i < arguments.nantennas; i++) {
    curandGenerateUniform(gen, (float*)packedData[i], packedBytes * (sizeof(int8_t) / sizeof(float)));
    curandGenerateUniform(gen, (float*)packedData8[i], packedBytes8 * (sizeof(int8_t) / sizeof(float)));
  }
  curandDestroyGenerator(gen);

  timerAdd(&timers, "calculateDelaysAndPhases");
  
  for (i = 0; i < arguments.nloops; i++) {
    if (arguments.verbose) {
      printf("\nLOOP %d\n", i);
    }

    // Run the delay calculator.
    if (arguments.verbose) {
      printf("  RUNNING DELAY KERNEL...");
      printf("   blocks = x: %d y: %d\n", FringeSetblocks.x, FringeSetblocks.y);
      printf("   threads = %d\n", numffts / 8);
    }
    timerStart(&timers, "calculateDelaysAndPhases");
    calculateDelaysAndPhases<<<FringeSetblocks, numffts/8>>>(gpuDelays, lo, sampletime,
							     fftchannels,
							     arguments.nchannels,
							     samplegranularity,
							     rotationPhaseInfo,
							     sampleShift,
							     fractionalSampleDelays);
    timerResult = timerEnd(&timers);
    if (arguments.verbose) {
      printf("  done in %8.3f ms.\n", timerResult);
    }
    
    // Now do the unpacking.
    preLaunchCheck();
    if (arguments.verbose) {
      printf("  RUNNING KERNEL... ");
    }
    cudaEventRecord(start_test_unpack, 0);
    for (j = 0; j < arguments.nantennas; j++) {
      old_unpack2bit_2chan<<<unpackBlocks, arguments.nthreads>>>(unpackedData, packedData[j], j);
    }
    cudaEventRecord(end_test_unpack, 0);
    cudaEventSynchronize(end_test_unpack);
    cudaEventElapsedTime(&(dtime_unpack[i]), start_test_unpack, end_test_unpack);
    if (arguments.verbose) {
      printf("  done in %8.3f ms.\n", dtime_unpack[i]);
    }
    postLaunchCheck();

    preLaunchCheck();
    if (arguments.verbose) {
      printf("  RUNNING KERNEL 2... ");
    }
    cudaEventRecord(start_test_unpack2, 0);
    for (j = 0; j < arguments.nantennas; j++) {
      unpack2bit_2chan<<<unpackBlocks, arguments.nthreads>>>(&unpackedData2[2*j*arguments.nsamples], packedData[j]);
    }
    cudaEventRecord(end_test_unpack2, 0);
    cudaEventSynchronize(end_test_unpack2);
    cudaEventElapsedTime(&(dtime_unpack2[i]), start_test_unpack2, end_test_unpack2);
    if (arguments.verbose) {
      printf("  done in %8.3f ms.\n", dtime_unpack2[i]);
    }
    postLaunchCheck();

    preLaunchCheck();
    if (arguments.verbose) {
      printf("  RUNNING KERNEL 3... ");
    }
    cudaEventRecord(start_test_unpack3, 0);
    for (j = 0; j < arguments.nantennas; j++) {
      init_2bitLevels();
      unpack2bit_2chan_fast<<<unpackBlocks, arguments.nthreads>>>(&unpackedData2[2*j*arguments.nsamples], packedData[j], sampleShift);
    }
    cudaEventRecord(end_test_unpack3, 0);
    cudaEventSynchronize(end_test_unpack3);
    cudaEventElapsedTime(&(dtime_unpack3[i]), start_test_unpack3, end_test_unpack3);
    if (arguments.verbose) {
      printf("  done in %8.3f ms.\n", dtime_unpack3[i]);
    }
    postLaunchCheck();

    preLaunchCheck();
    if (arguments.verbose) {
      printf("  RUNNING KERNEL 4... ");
    }
    cudaEventRecord(start_test_unpack4, 0);
    for (j = 0; j < arguments.nantennas; j++) {
      init_2bitLevels();
      unpack8bitcomplex_2chan<<<unpackBlocks, arguments.nthreads>>>(&unpackedData2[2*j*arguments.nsamples], packedData8[j]);
    }
    cudaEventRecord(end_test_unpack4, 0);
    cudaEventSynchronize(end_test_unpack4);
    cudaEventElapsedTime(&(dtime_unpack4[i]), start_test_unpack4, end_test_unpack4);
    if (arguments.verbose) {
      printf("  done in %8.3f ms.\n", dtime_unpack4[i]);
    }
    postLaunchCheck();
  }
  (void)time_stats(dtime_unpack, arguments.nloops, &averagetime_unpack,
		   &mintime_unpack, &maxtime_unpack);
  (void)time_stats(dtime_unpack2, arguments.nloops, &averagetime_unpack2,
		   &mintime_unpack2, &maxtime_unpack2);
  (void)time_stats(dtime_unpack3, arguments.nloops, &averagetime_unpack3,
       &mintime_unpack3, &maxtime_unpack3);
  (void)time_stats(dtime_unpack4, arguments.nloops, &averagetime_unpack4,
       &mintime_unpack4, &maxtime_unpack4);
  implied_time = (float)arguments.nsamples;
  if (arguments.complexdata) {
    // Bandwidth is the same as the sampling rate.
    implied_time /= (float)arguments.bandwidth;
    // But the data is twice as big.
    implied_time /= 2;
  } else {
    implied_time /= 2 * (float)arguments.bandwidth;
  }
  timerPrintStatistics(&timers, "calculateDelaysAndPhases", implied_time);
  
  printf("\n==== ROUTINE: old_unpack2bit_2chan ====\n");
  printf("Iterations | Average time |  Min time   |  Max time   | Data time  | Speed up  |\n");
  printf("%5d      | %8.3f ms  | %8.3f ms | %8.3f ms | %8.3f s | %8.3f  |\n", (arguments.nloops - 1),
	 averagetime_unpack, mintime_unpack, maxtime_unpack, implied_time,
	 ((implied_time * 1e3) / averagetime_unpack));
  printf("\n==== ROUTINE: unpack2bit_2chan ====\n");
  printf("Iterations | Average time |  Min time   |  Max time   | Data time  | Speed up  |\n");
  printf("%5d      | %8.3f ms  | %8.3f ms | %8.3f ms | %8.3f s | %8.3f  |\n", (arguments.nloops - 1),
	 averagetime_unpack2, mintime_unpack2, maxtime_unpack2, implied_time,
	 ((implied_time * 1e3) / averagetime_unpack2));
  printf("\n==== ROUTINE: unpack2bit_2chan_fast ====\n");
  printf("Iterations | Average time |  Min time   |  Max time   | Data time  | Speed up  |\n");
  printf("%5d      | %8.3f ms  | %8.3f ms | %8.3f ms | %8.3f s | %8.3f  |\n", (arguments.nloops - 1),
   averagetime_unpack3, mintime_unpack3, maxtime_unpack3, implied_time,
   ((implied_time * 1e3) / averagetime_unpack3));
  printf("\n==== ROUTINE: unpack28itcomplex_2chan ====\n");
  printf("Iterations | Average time |  Min time   |  Max time   | Data time  | Speed up  |\n");
  printf("%5d      | %8.3f ms  | %8.3f ms | %8.3f ms | %8.3f s | %8.3f  |\n", (arguments.nloops - 1),
   averagetime_unpack4, mintime_unpack4, maxtime_unpack4, implied_time,
   ((implied_time * 1e3) / averagetime_unpack4));
  
  
  // Clean up.
  cudaEventDestroy(start_test_unpack);
  cudaEventDestroy(end_test_unpack);
  cudaEventDestroy(start_test_unpack2);
  cudaEventDestroy(end_test_unpack2);
  cudaEventDestroy(start_test_unpack3);
  cudaEventDestroy(end_test_unpack3);
  cudaEventDestroy(start_test_unpack4);
  cudaEventDestroy(end_test_unpack4);


  /*
   * This benchmarks the performance of the fringe rotator kernel.
   */
  cuComplex *unpackedFR;
  /* A suitable array has already been defined and populated. */
  unpackedFR = unpackedData2;
  float *dtime_fringerotate=NULL, averagetime_fringerotate = 0.0;
  float mintime_fringerotate = 0.0, maxtime_fringerotate = 0.0;
  float *dtime_fringerotate2=NULL, averagetime_fringerotate2 = 0.0;
  float mintime_fringerotate2 = 0.0, maxtime_fringerotate2 = 0.0;
  float *rotVec;
  cudaEvent_t start_test_fringerotate, end_test_fringerotate;
  cudaEvent_t start_test_fringerotate2, end_test_fringerotate2;
  dim3 fringeBlocks;
  dtime_fringerotate = (float *)malloc(arguments.nloops * sizeof(float));
  dtime_fringerotate2 = (float *)malloc(arguments.nloops * sizeof(float));
  
  // Work out the block and thread numbers.
  fringeBlocks = dim3((arguments.nchannels / arguments.nthreads), numffts, arguments.nantennas);
  printf("\n\nEach fringe rotation test will run:\n");
  printf("  nsamples = %d\n", arguments.nsamples);
  printf("  nchannels = %d\n", arguments.nchannels);
  printf("  nffts = %d\n", numffts);
  
  cudaEventCreate(&start_test_fringerotate);
  cudaEventCreate(&end_test_fringerotate);
  cudaEventCreate(&start_test_fringerotate2);
  cudaEventCreate(&end_test_fringerotate2);

  /* Allocate memory for the rotation vector. */
  gpuErrchk(cudaMalloc(&rotVec, arguments.nantennas * numffts * 2 * sizeof(float)));
  /* Fill it with random data. */
  curandCreateGenerator(&gen, CURAND_RNG_PSEUDO_DEFAULT);
  curandSetPseudoRandomGeneratorSeed(gen, time(NULL));
  curandGenerateUniform(gen, rotVec, arguments.nantennas * numffts * 2);
  curandDestroyGenerator(gen);

  for (i = 0; i < arguments.nloops; i++) {
    
    preLaunchCheck();
    cudaEventRecord(start_test_fringerotate2, 0);

    //setFringeRotation<<<FringeSetblocks, numffts/8>>>(rotVec);
    FringeRotate2<<<fringeBlocks, arguments.nthreads>>>(unpackedFR, rotVec);
    
    cudaEventRecord(end_test_fringerotate2, 0);
    cudaEventSynchronize(end_test_fringerotate2);
    cudaEventElapsedTime(&(dtime_fringerotate2[i]), start_test_fringerotate2,
			 end_test_fringerotate2);
    postLaunchCheck();

    preLaunchCheck();
    cudaEventRecord(start_test_fringerotate, 0);

    //setFringeRotation<<<FringeSetblocks, numffts/8>>>(rotVec);
    FringeRotate<<<fringeBlocks, arguments.nthreads>>>(unpackedFR, rotVec);
    
    cudaEventRecord(end_test_fringerotate, 0);
    cudaEventSynchronize(end_test_fringerotate);
    cudaEventElapsedTime(&(dtime_fringerotate[i]), start_test_fringerotate,
			 end_test_fringerotate);
    postLaunchCheck();

  }
  // Do some statistics.
  (void)time_stats(dtime_fringerotate, arguments.nloops, &averagetime_fringerotate,
		   &mintime_fringerotate, &maxtime_fringerotate);
  (void)time_stats(dtime_fringerotate2, arguments.nloops, &averagetime_fringerotate2,
		   &mintime_fringerotate2, &maxtime_fringerotate2);
  printf("\n==== ROUTINES: FringeRotate ====\n");
  printf("Iterations | Average time |  Min time   |  Max time   | Data time  | Speed up  |\n");
  printf("%5d      | %8.3f ms  | %8.3f ms | %8.3f ms | %8.3f s | %8.3f  |\n",
	 (arguments.nloops - 1),
	 averagetime_fringerotate, mintime_fringerotate, maxtime_fringerotate, implied_time,
	 ((implied_time * 1e3) / averagetime_fringerotate));
  printf("\n==== ROUTINES: FringeRotate2 ====\n");
  printf("Iterations | Average time |  Min time   |  Max time   | Data time  | Speed up  |\n");
  printf("%5d      | %8.3f ms  | %8.3f ms | %8.3f ms | %8.3f s | %8.3f  |\n",
	 (arguments.nloops - 1),
	 averagetime_fringerotate2, mintime_fringerotate2, maxtime_fringerotate2, implied_time,
	 ((implied_time * 1e3) / averagetime_fringerotate2));
  cudaEventDestroy(start_test_fringerotate);
  cudaEventDestroy(end_test_fringerotate);
  cudaEventDestroy(start_test_fringerotate2);
  cudaEventDestroy(end_test_fringerotate2);


  /*
   * This benchmarks the performance of the FFT.
   */
  cufftHandle plan;
  cudaEvent_t start_test_fft, end_test_fft;
  float *dtime_fft=NULL, averagetime_fft = 0.0;
  float mintime_fft = 0.0, maxtime_fft = 0.0;
  cuComplex *channelisedData;
  int nbaseline = arguments.nantennas * (arguments.nantennas - 1) / 2;
  int parallelAccum = (int)ceil(arguments.nthreads / arguments.nchannels + 1);
  int rc;
  while (parallelAccum && numffts % parallelAccum) parallelAccum--;
  if (parallelAccum == 0) {
    printf("Error: can not determine block size for the cross correlator!\n");
    exit(0);
  }
  dtime_fft = (float *)malloc(arguments.nloops * sizeof(float));

  cudaEventCreate(&start_test_fft);
  cudaEventCreate(&end_test_fft);

  printf("\n\nEach fringe rotation test will run:\n");
  printf("  parallelAccum = %d\n", parallelAccum);
  printf("  nbaselines = %d\n", nbaseline);
  
  /* Allocate the necessary arrays. */
  gpuErrchk(cudaMalloc(&channelisedData, arguments.nantennas * npolarisations *
		       arguments.nsamples * sizeof(cuComplex)));
  if (rc = cufftPlan1d(&plan, fftchannels, CUFFT_C2C,
		       2 * arguments.nantennas * numffts) != CUFFT_SUCCESS) {
    printf("FFT planning failed! %d\n", rc);
    exit(0);
  }
  for (i = 0; i < arguments.nloops; i++) {

    preLaunchCheck();
    cudaEventRecord(start_test_fft, 0);
    if (cufftExecC2C(plan, unpackedFR, channelisedData, CUFFT_FORWARD) != CUFFT_SUCCESS) {
      printf("FFT execution failed!\n");
      exit(0);
    }
    
    cudaEventRecord(end_test_fft, 0);
    cudaEventSynchronize(end_test_fft);
    cudaEventElapsedTime(&(dtime_fft[i]), start_test_fft,
			 end_test_fft);
    postLaunchCheck();

  }
  cufftDestroy(plan);
    
  // Do some statistics.
  (void)time_stats(dtime_fft, arguments.nloops, &averagetime_fft,
		   &mintime_fft, &maxtime_fft);
  printf("\n==== ROUTINES: cufftExecC2C ====\n");
  printf("Iterations | Average time |  Min time   |  Max time   | Data time  | Speed up  |\n");
  printf("%5d      | %8.3f ms  | %8.3f ms | %8.3f ms | %8.3f s | %8.3f  |\n",
	 (arguments.nloops - 1),
	 averagetime_fft, mintime_fft, maxtime_fft, implied_time,
	 ((implied_time * 1e3) / averagetime_fft));

  cudaEventDestroy(start_test_fft);
  cudaEventDestroy(end_test_fft);
  
  /*
   * This benchmarks the performance of the cross-correlator and accumulator
   * combination.
   */
  cudaEvent_t start_test_crosscorr, end_test_crosscorr;
  cudaEvent_t start_test_crosscorr2, end_test_crosscorr2;
  cudaEvent_t start_test_crosscorr3, end_test_crosscorr3;
  cudaEvent_t start_test_accum, end_test_accum;
  float *dtime_crosscorr=NULL, averagetime_crosscorr = 0.0;
  float mintime_crosscorr = 0.0, maxtime_crosscorr = 0.0;
  float *dtime_crosscorr2=NULL, averagetime_crosscorr2 = 0.0;
  float mintime_crosscorr2 = 0.0, maxtime_crosscorr2 = 0.0;
  float *dtime_crosscorr3=NULL, averagetime_crosscorr3 = 0.0;
  float mintime_crosscorr3 = 0.0, maxtime_crosscorr3 = 0.0;
  float *dtime_accum=NULL, averagetime_accum = 0.0;
  float mintime_accum = 0.0, maxtime_accum = 0.0;
  int corrThreads, blockchan, nchunk, ccblock_width = 128;
  cuComplex *baselineData;
  dim3 corrBlocks, accumBlocks, ccblock, ccblock2;
  dtime_crosscorr = (float *)malloc(arguments.nloops * sizeof(float));
  dtime_crosscorr2 = (float *)malloc(arguments.nloops * sizeof(float));
  dtime_crosscorr3 = (float *)malloc(arguments.nloops * sizeof(float));
  dtime_accum = (float *)malloc(arguments.nloops * sizeof(float));
  
  gpuErrchk(cudaMalloc(&baselineData, nbaseline * 4 * arguments.nchannels *
		       parallelAccum * sizeof(cuComplex)));

  if (arguments.nchannels <= 512) {
    corrThreads = arguments.nchannels;
    blockchan = 1;
  } else {
    corrThreads = 512;
    blockchan = arguments.nchannels / 512;
  }
  corrBlocks = dim3(blockchan, parallelAccum);
  accumBlocks = dim3(blockchan, 4, nbaseline);
  ccblock = dim3((1 + (arguments.nchannels - 1) / ccblock_width),
		 arguments.nantennas - 1, arguments.nantennas - 1);
  ccblock2 = dim3((1 + (arguments.nchannels - 1) / ccblock_width),
		  (2 * arguments.nantennas -1), (2 * arguments.nantennas - 1));
  nchunk = numffts / parallelAccum;

  printf("\n\nEach cross correlation test will run:\n");
  printf("  parallelAccum = %d\n", parallelAccum);
  printf("  nbaselines = %d\n", nbaseline);
  printf("  corrThreads = %d\n", corrThreads);
  printf("  corrBlocks = x: %d , y: %d, z: %d\n", corrBlocks.x, corrBlocks.y, corrBlocks.z);
  printf("  accumBlocks = x: %d , y: %d, z: %d\n", accumBlocks.x, accumBlocks.y, accumBlocks.z);
  printf("  nchunk = %d\n", nchunk);
  printf("  ccblock_width = %d\n", ccblock_width);
  printf("  ccblock = x: %d , y: %d, z: %d\n", ccblock.x, ccblock.y, ccblock.z);
  printf("  ccblock2 = x: %d , y: %d, z: %d\n", ccblock2.x, ccblock2.y, ccblock2.z);

  
  cudaEventCreate(&start_test_crosscorr);
  cudaEventCreate(&end_test_crosscorr);
  cudaEventCreate(&start_test_crosscorr2);
  cudaEventCreate(&end_test_crosscorr2);
  cudaEventCreate(&start_test_crosscorr3);
  cudaEventCreate(&end_test_crosscorr3);
  cudaEventCreate(&start_test_accum);
  cudaEventCreate(&end_test_accum);
  for (i = 0; i < arguments.nloops; i++) {

    preLaunchCheck();
    cudaEventRecord(start_test_crosscorr, 0);
    CrossCorr<<<corrBlocks, corrThreads>>>(channelisedData, baselineData,
					   arguments.nantennas, nchunk);
    cudaEventRecord(end_test_crosscorr, 0);
    cudaEventSynchronize(end_test_crosscorr);
    cudaEventElapsedTime(&(dtime_crosscorr[i]), start_test_crosscorr,
			 end_test_crosscorr);
    postLaunchCheck();

    preLaunchCheck();
    cudaEventRecord(start_test_accum, 0);
    finaliseAccum<<<accumBlocks, corrThreads>>>(baselineData, parallelAccum, nchunk);
    cudaEventRecord(end_test_accum, 0);
    cudaEventSynchronize(end_test_accum);
    cudaEventElapsedTime(&(dtime_accum[i]), start_test_accum,
			 end_test_accum);
    postLaunchCheck();

    preLaunchCheck();
    cudaEventRecord(start_test_crosscorr2, 0);
    CrossCorrAccumHoriz<<<ccblock, ccblock_width>>>(baselineData, channelisedData,
						    arguments.nantennas, numffts,
						    arguments.nchannels, fftchannels);
    cudaEventRecord(end_test_crosscorr2, 0);
    cudaEventSynchronize(end_test_crosscorr2);
    cudaEventElapsedTime(&(dtime_crosscorr2[i]), start_test_crosscorr2,
			 end_test_crosscorr2);
    postLaunchCheck();

    preLaunchCheck();
    cudaEventRecord(start_test_crosscorr3, 0);
    CCAH2<<<ccblock, ccblock_width>>>(baselineData, channelisedData,
				      arguments.nantennas, numffts,
				      arguments.nchannels, fftchannels);
    cudaEventRecord(end_test_crosscorr3, 0);
    cudaEventSynchronize(end_test_crosscorr3);
    cudaEventElapsedTime(&(dtime_crosscorr3[i]), start_test_crosscorr3,
			 end_test_crosscorr3);
    postLaunchCheck();
    
  }
  // Do some statistics.
  (void)time_stats(dtime_crosscorr, arguments.nloops, &averagetime_crosscorr,
		   &mintime_crosscorr, &maxtime_crosscorr);
  printf("\n==== ROUTINES: CrossCorr ====\n");
  printf("Iterations | Average time |  Min time   |  Max time   | Data time  | Speed up  |\n");
  printf("%5d      | %8.3f ms  | %8.3f ms | %8.3f ms | %8.3f s | %8.3f  |\n",
	 (arguments.nloops - 1),
	 averagetime_crosscorr, mintime_crosscorr, maxtime_crosscorr, implied_time,
	 ((implied_time * 1e3) / averagetime_crosscorr));
  (void)time_stats(dtime_accum, arguments.nloops, &averagetime_accum,
		   &mintime_accum, &maxtime_accum);
  printf("\n==== ROUTINES: finaliseAccum ====\n");
  printf("Iterations | Average time |  Min time   |  Max time   | Data time  | Speed up  |\n");
  printf("%5d      | %8.3f ms  | %8.3f ms | %8.3f ms | %8.3f s | %8.3f  |\n",
	 (arguments.nloops - 1),
	 averagetime_accum, mintime_accum, maxtime_accum, implied_time,
	 ((implied_time * 1e3) / averagetime_accum));
  (void)time_stats(dtime_crosscorr2, arguments.nloops, &averagetime_crosscorr2,
		   &mintime_crosscorr2, &maxtime_crosscorr2);
  printf("\n==== ROUTINES: CrossCorrAccumHoriz ====\n");
  printf("Iterations | Average time |  Min time   |  Max time   | Data time  | Speed up  |\n");
  printf("%5d      | %8.3f ms  | %8.3f ms | %8.3f ms | %8.3f s | %8.3f  |\n",
	 (arguments.nloops - 1),
	 averagetime_crosscorr2, mintime_crosscorr2, maxtime_crosscorr2, implied_time,
	 ((implied_time * 1e3) / averagetime_crosscorr2));
  (void)time_stats(dtime_crosscorr3, arguments.nloops, &averagetime_crosscorr3,
		   &mintime_crosscorr3, &maxtime_crosscorr3);
  printf("\n==== ROUTINES: CCAH2 ====\n");
  printf("Iterations | Average time |  Min time   |  Max time   | Data time  | Speed up  |\n");
  printf("%5d      | %8.3f ms  | %8.3f ms | %8.3f ms | %8.3f s | %8.3f  |\n",
	 (arguments.nloops - 1),
	 averagetime_crosscorr3, mintime_crosscorr3, maxtime_crosscorr3, implied_time,
	 ((implied_time * 1e3) / averagetime_crosscorr3));

  
  cudaEventDestroy(start_test_crosscorr);
  cudaEventDestroy(end_test_crosscorr);
  cudaEventDestroy(start_test_crosscorr2);
  cudaEventDestroy(end_test_crosscorr2);
  cudaEventDestroy(start_test_crosscorr3);
  cudaEventDestroy(end_test_crosscorr3);
  cudaEventDestroy(start_test_accum);
  cudaEventDestroy(end_test_accum);
  
  
}


