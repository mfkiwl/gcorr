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

void time_stats_single(float *timearray, int ntime, float **output) {
  int i = 0;
  *output = (float *)malloc(3 * sizeof(float));

  (*output)[0] = 0.0;
  for (i = 1; i < ntime; i++) {
    (*output)[0] += timearray[i];
    if (i == 1) {
      (*output)[1] = timearray[i];
      (*output)[2] = timearray[i];
    } else {
      (*output)[1] = (timearray[i] < (*output)[1]) ? timearray[i] : (*output)[1];
      (*output)[2] = (timearray[i] > (*output)[2]) ? timearray[i] : (*output)[2];
    }
  }

  if ((ntime - 1) > 0) {
    (*output)[0] /= (float)(ntime - 1);
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
  float implied_time;
  dim3 FringeSetblocks;
  double *gpuDelays, **delays, *antfileoffsets;
  double lo, sampletime;
  float *rotationPhaseInfo, *fractionalSampleDelays;

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
  
  // Generate some random data.
  curandCreateGenerator(&gen, CURAND_RNG_PSEUDO_DEFAULT);
  curandSetPseudoRandomGeneratorSeed(gen, time(NULL));
  for (i = 0; i < arguments.nantennas; i++) {
    curandGenerateUniform(gen, (float*)packedData[i], packedBytes * (sizeof(int8_t) / sizeof(float)));
    curandGenerateUniform(gen, (float*)packedData8[i], packedBytes8 * (sizeof(int8_t) / sizeof(float)));
  }
  curandDestroyGenerator(gen);

  timerAdd(&timers, "calculateDelaysAndPhases");
  timerAdd(&timers, "old_unpack2bit_2chan");
  timerAdd(&timers, "unpack2bit_2chan");
  timerAdd(&timers, "unpack2bit_2chan_fast");
  timerAdd(&timers, "unpack8bitcomplex_2chan");
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
    if (arguments.verbose) {
      printf("  RUNNING KERNEL... ");
    }
    timerStart(&timers, "old_unpack2bit_2chan");
    for (j = 0; j < arguments.nantennas; j++) {
      old_unpack2bit_2chan<<<unpackBlocks, arguments.nthreads>>>(unpackedData, packedData[j], j);
    }
    timerResult = timerEnd(&timers);
    if (arguments.verbose) {
      printf("  done in %8.3f ms.\n", timerResult);
    }

    if (arguments.verbose) {
      printf("  RUNNING KERNEL 2... ");
    }
    timerStart(&timers, "unpack2bit_2chan");
    for (j = 0; j < arguments.nantennas; j++) {
      unpack2bit_2chan<<<unpackBlocks, arguments.nthreads>>>(&unpackedData2[2*j*arguments.nsamples], packedData[j]);
    }
    timerResult = timerEnd(&timers);
    if (arguments.verbose) {
      printf("  done in %8.3f ms.\n", timerResult);
    }

    if (arguments.verbose) {
      printf("  RUNNING KERNEL 3... ");
    }
    timerStart(&timers, "unpack2bit_2chan_fast");
    for (j = 0; j < arguments.nantennas; j++) {
      init_2bitLevels();
      unpack2bit_2chan_fast<<<unpackBlocks, arguments.nthreads>>>(&unpackedData2[2*j*arguments.nsamples], packedData[j], sampleShift);
    }
    timerResult = timerEnd(&timers);
    if (arguments.verbose) {
      printf("  done in %8.3f ms.\n", timerResult);
    }

    if (arguments.verbose) {
      printf("  RUNNING KERNEL 4... ");
    }
    timerStart(&timers, "unpack8bitcomplex_2chan");
    for (j = 0; j < arguments.nantennas; j++) {
      init_2bitLevels();
      unpack8bitcomplex_2chan<<<unpackBlocks, arguments.nthreads>>>(&unpackedData2[2*j*arguments.nsamples], packedData8[j]);
    }
    timerResult = timerEnd(&timers);
    if (arguments.verbose) {
      printf("  done in %8.3f ms.\n", timerResult);
    }
  }
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
  timerPrintStatistics(&timers, "old_unpack2bit_2chan", implied_time);
  timerPrintStatistics(&timers, "unpack2bit_2chan", implied_time);
  timerPrintStatistics(&timers, "unpack2bit_2chan_fast", implied_time);
  timerPrintStatistics(&timers, "unpack8bitcomplex_2chan", implied_time);


  /*
   * This benchmarks the performance of the fringe rotator kernel.
   */
  cuComplex *unpackedFR;
  /* A suitable array has already been defined and populated. */
  unpackedFR = unpackedData2;
  float *rotVec;
  dim3 fringeBlocks;
  
  // Work out the block and thread numbers.
  fringeBlocks = dim3((arguments.nchannels / arguments.nthreads), numffts, arguments.nantennas);
  printf("\n\nEach fringe rotation test will run:\n");
  printf("  nsamples = %d\n", arguments.nsamples);
  printf("  nchannels = %d\n", arguments.nchannels);
  printf("  nffts = %d\n", numffts);
  
  /* Allocate memory for the rotation vector. */
  gpuErrchk(cudaMalloc(&rotVec, arguments.nantennas * numffts * 2 * sizeof(float)));
  /* Fill it with random data. */
  curandCreateGenerator(&gen, CURAND_RNG_PSEUDO_DEFAULT);
  curandSetPseudoRandomGeneratorSeed(gen, time(NULL));
  curandGenerateUniform(gen, rotVec, arguments.nantennas * numffts * 2);
  curandDestroyGenerator(gen);

  timerAdd(&timers, "FringeRotate2");
  timerAdd(&timers, "FringeRotate");
  for (i = 0; i < arguments.nloops; i++) {
    
    timerStart(&timers, "FringeRotate2");
    FringeRotate2<<<fringeBlocks, arguments.nthreads>>>(unpackedFR, rotVec);
    timerEnd(&timers);
    
    timerStart(&timers, "FringeRotate");
    FringeRotate<<<fringeBlocks, arguments.nthreads>>>(unpackedFR, rotVec);
    timerEnd(&timers);
    
  }
  timerPrintStatistics(&timers, "FringeRotate", implied_time);
  timerPrintStatistics(&timers, "FringeRotate2", implied_time);

  /*
   * This benchmarks the performance of the FFT.
   */
  cufftHandle plan;
  cuComplex *channelisedData;
  int nbaseline = arguments.nantennas * (arguments.nantennas - 1) / 2;
  int parallelAccum = (int)ceil(arguments.nthreads / arguments.nchannels + 1);
  int rc;
  while (parallelAccum && numffts % parallelAccum) parallelAccum--;
  if (parallelAccum == 0) {
    printf("Error: can not determine block size for the cross correlator!\n");
    exit(0);
  }

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

  timerAdd(&timers, "cufftExecC2C");
  for (i = 0; i < arguments.nloops; i++) {

    timerStart(&timers, "cufftExecC2C");
    if (cufftExecC2C(plan, unpackedFR, channelisedData, CUFFT_FORWARD) != CUFFT_SUCCESS) {
      printf("FFT execution failed!\n");
      exit(0);
    }
    timerEnd(&timers);

  }
  cufftDestroy(plan);
  timerPrintStatistics(&timers, "cufftExecC2C", implied_time);
  
  /*
   * This benchmarks the performance of the cross-correlator and accumulator
   * combination.
   */
  int corrThreads, blockchan, nchunk, ccblock_width = 128;
  cuComplex *baselineData;
  dim3 corrBlocks, accumBlocks, ccblock, ccblock2;
  
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

  timerAdd(&timers, "CrossCorr");
  timerAdd(&timers, "finaliseAccum");
  timerAdd(&timers, "CrossCorrAccumHoriz");
  timerAdd(&timers, "CCAH2");
  for (i = 0; i < arguments.nloops; i++) {

    timerStart(&timers, "CrossCorr");
    CrossCorr<<<corrBlocks, corrThreads>>>(channelisedData, baselineData,
					   arguments.nantennas, nchunk);
    timerEnd(&timers);
    
    timerStart(&timers, "finaliseAccum");
    finaliseAccum<<<accumBlocks, corrThreads>>>(baselineData, parallelAccum, nchunk);
    timerEnd(&timers);
    
    timerStart(&timers, "CrossCorrAccumHoriz");
    CrossCorrAccumHoriz<<<ccblock, ccblock_width>>>(baselineData, channelisedData,
						    arguments.nantennas, numffts,
						    arguments.nchannels, fftchannels);
    timerEnd(&timers);
    
    timerStart(&timers, "CCAH2");
    CCAH2<<<ccblock, ccblock_width>>>(baselineData, channelisedData,
				      arguments.nantennas, numffts,
				      arguments.nchannels, fftchannels);
    timerEnd(&timers);
  }
  timerPrintStatistics(&timers, "CrossCorr", implied_time);
  timerPrintStatistics(&timers, "finaliseAccum", implied_time);
  timerPrintStatistics(&timers, "CrossCorrAccumHoriz", implied_time);
  timerPrintStatistics(&timers, "CCAH2", implied_time);
  
  
}


