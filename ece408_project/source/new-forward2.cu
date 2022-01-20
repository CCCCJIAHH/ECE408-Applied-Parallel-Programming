#include <cmath>
#include <iostream>
#include "gpu-new-forward.h"

#define TILE_WIDTH 16

__global__ void
conv_forward_kernel(float *y, const float *x, const float *k, const int B, const int M, const int C, const int H,
                    const int W, const int K) {
    /*
    Modify this function to implement the forward pass described in Chapter 16.
    We have added an additional dimension to the tensors to support an entire mini-batch
    The goal here is to be correct AND fast.

    Function paramter definitions:
    y - output
    x - input
    k - kernel
    B - batch_size (number of images in x)
    M - number of output feature maps
    C - number of input feature maps
    H - input height dimension
    W - input width dimension
    K - kernel height and width (K x K)
    */

    const int H_out = H - K + 1;
    const int W_out = W - K + 1;

    int W_grid = ceil(1.0*W_out/16.0);
    int X_out_width = TILE_WIDTH + K -1;

    extern __shared__ float shared_mem[];

    float* X_shared=&shared_mem[0];
    float* W_shared=&shared_mem[X_out_width * X_out_width];
//    (void)H_out; // silence declared but never referenced warning. remove this line when you start working
//    (void)W_out; // silence declared but never referenced warning. remove this line when you start working

    // We have some nice #defs for you below to simplify indexing. Feel free to use them, or create your own.
    // An example use of these macros:
    // float a = y4d(0,0,0,0)
    // y4d(0,0,0,0) = a

#define y4d(i3, i2, i1, i0) y[(i3) * (M * H_out * W_out) + (i2) * (H_out * W_out) + (i1) * (W_out) + i0]
#define x4d(i3, i2, i1, i0) x[(i3) * (C * H * W) + (i2) * (H * W) + (i1) * (W) + i0]
#define k4d(i3, i2, i1, i0) k[(i3) * (C * K * K) + (i2) * (K * K) + (i1) * (K) + i0]

    // Insert your GPU convolution kernel code here
    int n = blockIdx.x;
    int m=blockIdx.y;
    int w0=threadIdx.x;
    int h0=threadIdx.y;

    int h_base=(blockIdx.z/W_grid)*TILE_WIDTH;
    int w_base=(blockIdx.z % W_grid)*TILE_WIDTH;

    int h=h_base+h0;
    int w=w_base+w0;

    float sum=0;

    for (int c=0; c<C; c++){
        if ((h0<K) && (w0<K)){
            W_shared[h0*K+w0]=k4d(m,c,h0,w0);
        }
        __syncthreads();

        for (int i=h; i<h_base+X_out_width; i+=TILE_WIDTH){
            for (int j=w; j<w_base+X_out_width; j+=TILE_WIDTH){
                if (i<H && j<W){
                    X_shared[(i-h_base)*(X_out_width)+(j-w_base)]=x4d(n,c,i,j);
                }
                else{
                    X_shared[(i-h_base)*(X_out_width)+(j-w_base)]=0;
                }
            }
        }
        __syncthreads();
        for (int p=0; p<K; p++){
            for (int q=0; q<K; q++){
                if(((h0+p) < X_out_width) && ((w0+q) < X_out_width)){
                    sum+=X_shared[(h0+p)*(X_out_width) + (w0+q)] * W_shared[p*K+q];
                }
            }
        }
        __syncthreads();
    }
    if (n<B && m<M && h<H_out && w<W_out){
        y4d(n,m,h,w)=sum;
    }
#undef y4d
#undef x4d
#undef k4d
}


__host__ void GPUInterface::conv_forward_gpu_prolog(const float *host_y, const float *host_x, const float *host_k,
                                                    float **device_y_ptr, float **device_x_ptr, float **device_k_ptr,
                                                    const int B, const int M, const int C, const int H, const int W,
                                                    const int K) {
    // Allocate memory and copy over the relevant data structures to the GPU

    // We pass double pointers for you to initialize the relevant device pointers,
    //  which are passed to the other two functions.
    const int H_out = H - K + 1;
    const int W_out = W - K + 1;

    cudaMalloc(device_y_ptr, B * M * H_out * W_out * sizeof(float));
    cudaMalloc(device_x_ptr, B * C * H * W * sizeof(float));
    cudaMalloc(device_k_ptr, M * C * K * K * sizeof(float));

    cudaMemcpy(*device_x_ptr, host_x, B * C * H * W * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(*device_k_ptr, host_k, M * C * K * K * sizeof(float), cudaMemcpyHostToDevice);


    // Useful snippet for error checking
    cudaError_t error = cudaGetLastError();
    if(error != cudaSuccess)
    {
        std::cout<<"CUDA error: "<<cudaGetErrorString(error)<<std::endl;
        exit(-1);
    }

}


__host__ void
GPUInterface::conv_forward_gpu(float *device_y, const float *device_x, const float *device_k, const int B, const int M,
                               const int C, const int H, const int W, const int K) {
    // Set the kernel dimensions and call the kernel
    const int H_out = H - K + 1;
    const int W_out = W - K + 1;

    int W_grid = ceil((float) W_out / TILE_WIDTH);
    int H_grid = ceil((float) H_out / TILE_WIDTH);
    int Z = H_grid * W_grid;
    dim3 blockDim(TILE_WIDTH, TILE_WIDTH, 1);
    dim3 gridDim(B, M, Z);

    conv_forward_kernel<<<gridDim, blockDim>>>(device_y, device_x, device_k, B, M, C, H, W, K);
}


__host__ void
GPUInterface::conv_forward_gpu_epilog(float *host_y, float *device_y, float *device_x, float *device_k, const int B,
                                      const int M, const int C, const int H, const int W, const int K) {
    // Copy the output back to host
    const int H_out = H - K + 1;
    const int W_out = W - K + 1;
    cudaMemcpy(host_y, device_y, B * M * H_out * W_out * sizeof(float), cudaMemcpyDeviceToHost);

    // Free device memory
    cudaFree(device_x);
    cudaFree(device_y);
    cudaFree(device_k);
}


__host__ void GPUInterface::get_device_properties() {
    int deviceCount;
    cudaGetDeviceCount(&deviceCount);

    for (int dev = 0; dev < deviceCount; dev++) {
        cudaDeviceProp deviceProp;
        cudaGetDeviceProperties(&deviceProp, dev);

        std::cout << "Device " << dev << " name: " << deviceProp.name << std::endl;
        std::cout << "Computational capabilities: " << deviceProp.major << "." << deviceProp.minor << std::endl;
        std::cout << "Max Global memory size: " << deviceProp.totalGlobalMem << std::endl;
        std::cout << "Max Constant memory size: " << deviceProp.totalConstMem << std::endl;
        std::cout << "Max Shared memory size per block: " << deviceProp.sharedMemPerBlock << std::endl;
        std::cout << "Max threads per block: " << deviceProp.maxThreadsPerBlock << std::endl;
        std::cout << "Max block dimensions: " << deviceProp.maxThreadsDim[0] << " x, " << deviceProp.maxThreadsDim[1]
                  << " y, " << deviceProp.maxThreadsDim[2] << " z" << std::endl;
        std::cout << "Max grid dimensions: " << deviceProp.maxGridSize[0] << " x, " << deviceProp.maxGridSize[1]
                  << " y, " << deviceProp.maxGridSize[2] << " z" << std::endl;
        std::cout << "Warp Size: " << deviceProp.warpSize << std::endl;
    }
}
