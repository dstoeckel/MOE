#include <stdio.h>
#include <curand_kernel.h>
#include <cuda_runtime.h>
#include <helper_cuda.h>
#include <helper_functions.h>
#include "gpp_cuda_math.hpp"

#define OL_CUDA_ERROR_RETURN(X) do{if(X != cudaSuccess){CudaError _err = {X, __FILE__, __LINE__}; return _err;}} while(0);

namespace optimal_learning {

namespace { // functions run on gpu device
/*
Special case of GeneralMatrixVectorMultiply.  As long as A has zeros in the strict upper-triangle,
GeneralMatrixVectorMultiply will work too (but take >= 2x as long).

Computes results IN-PLACE.
Avoids accessing the strict upper triangle of A.

Should be equivalent to BLAS call:
dtrmv('L', trans, 'N', size_m, A, size_m, x, 1);

comment: This function is copied from gpp_linear_algebra.cpp
*/
__device__ void TriangularMatrixVectorMultiply_gpu(double const * __restrict__ A, int size_m, double * __restrict__ x) {
 double temp;
 A += size_m * (size_m-1);
 for (int j = size_m-1; j >= 0; --j) {  // i.e., j >= 0
   temp = x[j];
   for (int i = size_m-1; i >= j+1; --i) {  
     // handles sub-diagonal contributions from j-th column
     x[i] += temp*A[i];
   }
   x[j] *= A[j];  // handles j-th on-diagonal component
   A -= size_m;
 }
}

/*
y = y - A * x (aka alpha = -1.0, beta = 1.0)

Computes matrix-vector product y = alpha * A * x + beta * y or y = alpha * A^T * x + beta * y
Since A is stored column-major, we need to treat the matrix-vector product as a weighted sum
of the columns of A, where x provides the weights.

That is, a matrix-vector product can be thought of as: (trans = 'T')
[  a_row1  ][   ]
[  a_row2  ][ x ]
[    ...   ][   ]
[  a_rowm  ][   ]
That is, y_i is the dot product of the i-th row of A with x.

OR the "dual" view: (trans = 'N')
[        |        |     |        ][ x_1 ]
[ a_col1 | a_col2 | ... | a_coln ][ ... ] = x_1*a_col1 + ... + x_n*a_coln
[        |        |     |        ][ x_n ]
That is, y is the weighted sum of columns of A.

Should be equivalent to BLAS call:
dgemv(trans='N', size_m, size_n, alpha, A, size_m, x, 1, beta, y, 1);

comment: This function is copied from gpp_linear_algebra.cpp
*/
__device__ void GeneralMatrixVectorMultiply_gpu(double const * __restrict__ A, double const * __restrict__ x, int size_m, int size_n, int lda, double * __restrict__ y) {
  double temp;
  for (int i = 0; i < size_n; ++i) {
    temp = -1.0 * x[i];
    for (int j = 0; j < size_m; ++j) {
      y[j] += A[j]*temp;
    }
    A += lda;
  }
}

__global__ void EI_gpu(double const * __restrict__ L, double const * __restrict__ mu, int no_of_pts, int NUM_ITS, double best, unsigned int seed, double * __restrict__ EIs, double* __restrict__ dev_random_number_EI, bool configure_for_test)
{
  // copy mu, L to shared memory mu_local & L_local 
  // For multiple dynamically sized arrays in a single kernel, declare a single extern unsized array, and use
  // pointers into it to divide it into multiple arrays
  // refer to http://devblogs.nvidia.com/parallelforall/using-shared-memory-cuda-cc/

  extern __shared__ double storage[];
  double * L_local = storage;
  double * mu_local = &L_local[no_of_pts * no_of_pts];
  const int idx = threadIdx.x;
  const int IDX = threadIdx.x + blockDim.x * blockIdx.x;
  const int loop_no = no_of_pts * no_of_pts / blockDim.x;
  for (int k = 0; k <= loop_no; ++k) {
    if (k * blockDim.x + idx < no_of_pts * no_of_pts)
        L_local[k*blockDim.x+idx] = L[k*blockDim.x+idx];
    if (k * blockDim.x + idx < no_of_pts)
        mu_local[k*blockDim.x+idx] = mu[k*blockDim.x+idx];
  }
  __syncthreads();

  // MC start
  // RNG setup
  unsigned int local_seed = seed + IDX;
  curandState s;
  // seed a random number generator
  curand_init(local_seed, 0, 0, &s);

  double *normals = (double *)malloc(sizeof(double)*no_of_pts);
  double agg = 0.0;
  double improvement_this_step;
  double EI;

  if (configure_for_test) {
      for(int mc = 0; mc < NUM_ITS; ++mc) {
        improvement_this_step = 0.0;
        for(int i = 0; i < no_of_pts; ++i) {
            normals[i] = curand_normal_double(&s);
            dev_random_number_EI[IDX * NUM_ITS * no_of_pts + mc * no_of_pts + i] = normals[i];
        }
        TriangularMatrixVectorMultiply_gpu(L_local, no_of_pts, normals);
        for(int i = 0; i < no_of_pts; ++i) {
            EI = best - (mu_local[i] + normals[i]);
            if(EI > improvement_this_step) {
                improvement_this_step = EI;
            }
        }
        agg += improvement_this_step;
      }
  } else {
      for(int mc = 0; mc < NUM_ITS; ++mc) {
        improvement_this_step = 0.0;
        for(int i = 0; i < no_of_pts; ++i) {
            normals[i] = curand_normal_double(&s);
        }
        TriangularMatrixVectorMultiply_gpu(L_local, no_of_pts, normals);
        for(int i = 0; i < no_of_pts; ++i) {
            EI = best - (mu_local[i] + normals[i]);
            if(EI > improvement_this_step) {
                improvement_this_step = EI;
            }
        }
        agg += improvement_this_step;
      }
  }
  EIs[IDX] = agg/(double)NUM_ITS;
  free(normals);
}

// grad_EIs[dim][num_to_sample][num_threads]
__global__ void grad_EI_gpu(double const * __restrict__ mu, double const * __restrict__ L, double const * __restrict__ grad_mu, double const * __restrict__ grad_L, double best, int num_union_of_pts, int num_to_sample, int dimension, int NUM_ITS, unsigned int seed,  double * __restrict__ grad_EIs, double* __restrict__ dev_random_number_gradEI, bool configure_for_test)
{
  // copy mu, L, grad_mu, grad_L to shared memory 
  extern __shared__ double storage[];
  double * mu_local = storage;
  double * L_local = &mu_local[num_union_of_pts];
  double * grad_mu_local = &L_local[num_union_of_pts * num_union_of_pts];
  double * grad_L_local = &grad_mu_local[num_to_sample * dimension];

  const int idx = threadIdx.x;
  const int IDX = threadIdx.x + blockDim.x * blockIdx.x;
  const int loop_no = num_to_sample * num_union_of_pts * num_union_of_pts * dimension / blockDim.x;
  for (int k = 0; k <= loop_no; ++k) {
      if (k * blockDim.x + idx < num_to_sample * num_union_of_pts * num_union_of_pts * dimension)
          grad_L_local[k*blockDim.x+idx] = grad_L[k*blockDim.x+idx];
      if (k * blockDim.x + idx < num_union_of_pts * num_union_of_pts)
          L_local[k*blockDim.x+idx] = L[k*blockDim.x+idx];
      if (k * blockDim.x + idx < num_to_sample * dimension)
          grad_mu_local[k*blockDim.x+idx] = grad_mu[k*blockDim.x+idx];
      if (k * blockDim.x + idx < num_union_of_pts)
          mu_local[k*blockDim.x+idx] = mu[k*blockDim.x+idx];
  }
  __syncthreads();
 
  int i, k, mc, winner;
  double EI, improvement_this_step;
  // RNG setup
  unsigned int local_seed = seed + IDX; 
  curandState s;
  // seed a random number generator
  curand_init(local_seed, 0, 0, &s);
  double* normals = (double*)malloc(sizeof(double) * num_union_of_pts);
  double* normals_copy = (double*)malloc(sizeof(double) * num_union_of_pts);
  // initialize grad_EIs
  for (int i = 0; i < num_to_sample; ++i) {
      for (int k = 0; k < dimension; ++k) {
          grad_EIs[IDX*num_to_sample*dimension + i*dimension + k] = 0.0;
      }
  }
  // MC step start
  if (configure_for_test) {
      for(mc = 0; mc < NUM_ITS; ++mc) {
          improvement_this_step = 0.0;
          winner = -1;
          for(i = 0; i < num_union_of_pts; ++i) {
              normals[i] = curand_normal_double(&s);
              normals_copy[i] = normals[i];
              dev_random_number_gradEI[IDX * NUM_ITS * num_union_of_pts + mc * num_union_of_pts + i] = normals[i];
          }
          TriangularMatrixVectorMultiply_gpu(L_local, num_union_of_pts, normals);
          for(i = 0; i < num_union_of_pts; ++i){
              EI = best - (mu_local[i] + normals[i]);
              if(EI > improvement_this_step){
                  improvement_this_step = EI;
                  winner = i;
              }
          }
          if(improvement_this_step > 0.0) {
              if (winner < num_to_sample) {
                  for (k = 0; k < dimension; ++k) {
                      grad_EIs[IDX*num_to_sample*dimension + winner * dimension + k] -= grad_mu_local[winner * dimension + k];
                  }
              }
              for (i = 0; i < num_to_sample; ++i) {   // derivative w.r.t ith point
                  GeneralMatrixVectorMultiply_gpu(grad_L_local + i*num_union_of_pts*num_union_of_pts*dimension + winner*num_union_of_pts*dimension, normals_copy, dimension, num_union_of_pts, dimension, grad_EIs + IDX*num_to_sample*dimension + i*dimension);
              }
          }
      }
  } else {
      for(mc = 0; mc < NUM_ITS; ++mc) {
          improvement_this_step = 0.0;
          winner = -1;
          for(i = 0; i < num_union_of_pts; ++i) {
              normals[i] = curand_normal_double(&s);
              normals_copy[i] = normals[i];
          }
          TriangularMatrixVectorMultiply_gpu(L_local, num_union_of_pts, normals);
          for(i = 0; i < num_union_of_pts; ++i){
              EI = best - (mu_local[i] + normals[i]);
              if(EI > improvement_this_step){
                  improvement_this_step = EI;
                  winner = i;
              }
          }
          //printf("grad_mu %f \n", grad_mu[which_point * dimension]);
          if(improvement_this_step > 0.0) {
              if (winner < num_to_sample) {
                  for (k = 0; k < dimension; ++k) {
                      grad_EIs[IDX*num_to_sample*dimension + winner * dimension + k] -= grad_mu_local[winner * dimension + k];
                  }
              }
              for (i = 0; i < num_to_sample; ++i) {   // derivative w.r.t ith point
                  GeneralMatrixVectorMultiply_gpu(grad_L_local + i*num_union_of_pts*num_union_of_pts*dimension + winner*num_union_of_pts*dimension, normals_copy, dimension, num_union_of_pts, dimension, grad_EIs + IDX*num_to_sample*dimension + i*dimension);
              }
          }
      }
  }

  for (int i = 0; i < num_to_sample; ++i) {
      for (int k = 0; k < dimension; ++k) {
          grad_EIs[IDX*num_to_sample*dimension + i*dimension + k] /= (double)NUM_ITS;
      }
  }
  // printf("gpu idx %d, value %f \n", idx, grad_EI_component[idx * dimension+1]);
  free(normals);
  free(normals_copy);
}

} // end unnamed namespace
    
extern "C" CudaError cuda_allocate_mem_for_double_vector(int num_doubles, double** __restrict__ ptr_to_ptr) {
  CudaError _success = {cudaSuccess, __FILE__, __LINE__};
  int mem_size = num_doubles * sizeof(double);
  OL_CUDA_ERROR_RETURN(cudaMalloc((void**) ptr_to_ptr, mem_size))
  return _success;
}

extern "C" void cuda_free_mem(double* __restrict__ ptr) {
  cudaFree(ptr);
}

extern "C" CudaError cuda_get_EI(double * __restrict__ mu, double * __restrict__ L, double best, int num_union_of_pts, double * __restrict__ dev_mu, double * __restrict__ dev_L, double * __restrict__ dev_EIs, unsigned int seed, int num_mc, double* __restrict__ ei_val, double* __restrict__ dev_random_number_EI, double* __restrict__ random_number_EI, bool configure_for_test) {
  *ei_val = 0.0;
  CudaError _success = {cudaSuccess, __FILE__, __LINE__};
  const unsigned int EI_thread_no = EI_THREAD_NO;
  const unsigned int EI_block_no = EI_BLOCK_NO;
  dim3 threads(EI_thread_no, 1, 1);
  dim3 grid(EI_block_no, 1, 1);
  double EIs[EI_thread_no * EI_block_no];
  // make sure NUM_ITS is always >= 1
  int NUM_ITS = num_mc / (EI_thread_no * EI_block_no) + 1;
  int mem_size_mu = num_union_of_pts * sizeof(double);
  int mem_size_L = num_union_of_pts * num_union_of_pts * sizeof(double);
  int mem_size_EIs = EI_thread_no * EI_block_no * sizeof(double);
  // copy mu, L to GPU
  OL_CUDA_ERROR_RETURN(cudaMemcpy(dev_mu, mu, mem_size_mu, cudaMemcpyHostToDevice))
  OL_CUDA_ERROR_RETURN(cudaMemcpy(dev_L, L, mem_size_L, cudaMemcpyHostToDevice))
  // execute kernel
  EI_gpu<<< grid, threads, num_union_of_pts*sizeof(double)+num_union_of_pts*num_union_of_pts*sizeof(double)>>>(dev_L, dev_mu, num_union_of_pts, NUM_ITS, best, seed, dev_EIs, dev_random_number_EI, configure_for_test); 
  OL_CUDA_ERROR_RETURN(cudaPeekAtLastError())
  // copy dev_EIs back to CPU
  OL_CUDA_ERROR_RETURN(cudaMemcpy(EIs, dev_EIs, mem_size_EIs, cudaMemcpyDeviceToHost))
  // copy dev_random_number_EI back to CPU if configure_for_test is on
  if (configure_for_test) {
      int mem_size_random_number_EI = NUM_ITS * EI_thread_no * EI_block_no * num_union_of_pts * sizeof(double);
      OL_CUDA_ERROR_RETURN(cudaMemcpy(random_number_EI, dev_random_number_EI, mem_size_random_number_EI, cudaMemcpyDeviceToHost))
  }
  // average EIs
  double ave = 0.0;
  for (int i=0;i<(EI_thread_no*EI_block_no);i++) {
      ave += EIs[i];
  }
  *ei_val = ave/ (double)(EI_thread_no*EI_block_no);
  return _success;
}

 // grad_EI[dim][num_to_sample]
 extern "C" CudaError cuda_get_gradEI(double * __restrict__ mu, double * __restrict__ grad_mu, double * __restrict__ L, double * __restrict__ grad_L, double best, int num_union_of_pts, int num_to_sample, int dimension, double * __restrict__ dev_mu, double * __restrict__ dev_grad_mu, double * __restrict__ dev_L, double * __restrict__ dev_grad_L, double * __restrict__ dev_grad_EIs, unsigned int seed, int num_mc, double * __restrict__ grad_EI, double* __restrict__
         dev_random_number_gradEI, double* __restrict__ random_number_gradEI, bool configure_for_test) {
  CudaError _success = {cudaSuccess, __FILE__, __LINE__};
  const unsigned int gradEI_thread_no = GRADEI_THREAD_NO;
  const unsigned int gradEI_block_no = GRADEI_BLOCK_NO;
  dim3 threads(gradEI_thread_no, 1, 1);
  dim3 grid(gradEI_block_no, 1, 1);
  // make sure NUM_ITS is always >= 1
  int NUM_ITS = num_mc / (gradEI_thread_no * gradEI_block_no) + 1;
  int mem_size_mu = num_union_of_pts * sizeof(double);
  int mem_size_grad_mu = num_to_sample * dimension * sizeof(double);
  int mem_size_L = num_union_of_pts * num_union_of_pts *sizeof(double);
  int mem_size_grad_L = num_to_sample * num_union_of_pts * num_union_of_pts * dimension * sizeof(double);
  int mem_size_grad_EIs = gradEI_thread_no * gradEI_block_no * num_to_sample * dimension * sizeof(double);
  double grad_EIs[num_to_sample * dimension * gradEI_thread_no * gradEI_block_no];
  // initialize grad_EI
  for (int i = 0; i < num_to_sample; ++i) {
      for (int k = 0; k < dimension; ++k) {
          grad_EI[i*dimension + k] = 0.0;
      }
  }
  // staff run on gpu
  // copy data to GPU
  OL_CUDA_ERROR_RETURN(cudaMemcpy(dev_mu, mu, mem_size_mu, cudaMemcpyHostToDevice))
  OL_CUDA_ERROR_RETURN(cudaMemcpy(dev_grad_mu, grad_mu, mem_size_grad_mu, cudaMemcpyHostToDevice))
  OL_CUDA_ERROR_RETURN(cudaMemcpy(dev_L, L, mem_size_L, cudaMemcpyHostToDevice))
  OL_CUDA_ERROR_RETURN(cudaMemcpy(dev_grad_L, grad_L, mem_size_grad_L, cudaMemcpyHostToDevice))
  // execute kernel
  grad_EI_gpu<<< grid, threads, mem_size_mu+mem_size_L+mem_size_grad_mu+mem_size_grad_L >>>(dev_mu, dev_L, dev_grad_mu, dev_grad_L, best, num_union_of_pts, num_to_sample, dimension, NUM_ITS, seed, dev_grad_EIs, dev_random_number_gradEI, configure_for_test); 
  OL_CUDA_ERROR_RETURN(cudaPeekAtLastError())
  // copy result back to CPU
  OL_CUDA_ERROR_RETURN(cudaMemcpy(grad_EIs, dev_grad_EIs, mem_size_grad_EIs, cudaMemcpyDeviceToHost))
  // copy dev_random_number_gradEI back to CPU if configure_for_test is on
  if (configure_for_test) {
      int mem_size_random_number_gradEI = NUM_ITS * gradEI_thread_no * gradEI_block_no * num_union_of_pts * sizeof(double);
      OL_CUDA_ERROR_RETURN(cudaMemcpy(random_number_gradEI, dev_random_number_gradEI, mem_size_random_number_gradEI, cudaMemcpyDeviceToHost))
  }
  // get grad_EI
  for (int n = 0; n < (gradEI_thread_no*gradEI_block_no); ++n) {
      for (int i = 0; i < num_to_sample; ++i) {
          for (int k = 0; k < dimension; ++k) {
              grad_EI[i*dimension + k] += grad_EIs[n*num_to_sample*dimension + i*dimension + k];
          }
      }
  }
  for (int i = 0; i < num_to_sample; ++i) {
      for (int k = 0; k < dimension; ++k) {
          grad_EI[i*dimension + k] /= (double)(gradEI_thread_no*gradEI_block_no);
      }
  }
  return _success;
}

extern "C" CudaError cuda_set_device(int devID) {
  CudaError _success = {cudaSuccess, __FILE__, __LINE__};
  OL_CUDA_ERROR_RETURN(cudaSetDevice(devID))
  return _success;
}

}    // end namespace optimal_learning

