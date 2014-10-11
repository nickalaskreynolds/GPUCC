/* 
 * File:   main.cu
 * Author: eaton
 * TO MAKE RUN: nvcc main.cu -L$CUDA_TOOLKIT_ROOT_DIR/lib64 -lcuda -lcufft
 * Created on September 23, 2014, 11:08 PM
 */
#include "main.h"
using namespace std;
/*
 * Polyphase filter prefilter as kernel
 */

__global__ void createFilter(float * out){
    int x = threadIdx.x + blockIdx.x * blockDim.x;
    int M = blockDim.x*gridDim.x;
    int N = blockDim.x;
    float temp1 = (2.0 * M_PI * (x*1.00 / M));
    float temp2 = (0.5-0.5*__cosf(temp1));
    float temp3 = (x-M/2.00)/N;
    if(temp3 != 0){
		out[x] = __sinf(temp3)/temp3;
    }
    else{
		out[x] = 1;
    }
}

/*
 * Apply prefilter as kernel
 * Sum outputs to one N size vector
 */

__global__ void appliedPolyphasePhysics(float * in, float * filter, float * ppf_out){
    int x = threadIdx.x + blockIdx.x * blockDim.x;
    in [x] *= filter[x];
    ppf_out [threadIdx.x] += in[x];
}

/*
 * Cojugate Function.
 */
__device__ __host__ inline cufftComplex cufftConj(cufftComplex in) {
	in.y = -in.y;
	return in;
}

__device__ __host__ inline cufftComplex cufftMult(cufftComplex a, cufftComplex b){
	cufftComplex c;
    c.x = a.x * b.x - a.y * b.y;
    c.y = a.x * b.y + a.y * b.x;
    return c;
}

/*
 * Cross correlate two vectors.
 */
__global__ void correlate(cufftComplex *in1, cufftComplex *in2, cufftComplex *out){
	int x = threadIdx.x + blockIdx.x*blockDim.x;
	out[x] = cufftMult(in1[x],cufftConj(in2[x]));
}

/*
 * Host main function
 */
int main(int argc, char** argv){
    vector<vector<float> > inputs;
	float * in1;
	float * in2;
	float * in1_d, *in2_d;
	float * prefilter_d;
	unsigned int M = 0;
	unsigned int N = 512;
	unsigned int threads;
	float * ppf_out1;
	float * ppf_out1_d;
	float * ppf_out2;
	float * ppf_out2_d;

    Read_data(inputs,"sampleinputs.csv");
	M = inputs[0].size();
	in1 = &inputs[0][0];
	in2 = &inputs[1][0];
	cudaMalloc((void **) &in1_d, M*sizeof(float));
	cudaMalloc((void **) &in2_d, M*sizeof(float));
	cudaMemcpy(in1_d, in1, M*sizeof(float),cudaMemcpyHostToDevice);
	cudaMemcpy(in2_d, in2, M*sizeof(float),cudaMemcpyHostToDevice);

//	cout << "not segfault. [1]\n";
	cudaMalloc((void **) &prefilter_d, M*sizeof(float));
	threads = M/N;
	createFilter<<<N,threads>>>(prefilter_d);

	ppf_out1 = new float[N];
	memset(ppf_out1, 0.00, N*sizeof(float));
	ppf_out2 = new float[N];
	memset(ppf_out1, 0.00, N*sizeof(float));
//	cout << "not segfault. [2]\n";
	cudaMalloc((void **) &ppf_out1_d,N*sizeof(float));
	cudaMalloc((void **) &ppf_out2_d,N*sizeof(float));
// Put this section inside kernel for less useless data traffic.
//	cout << "not segfault. [3]\n";
	cudaMemcpy(ppf_out1_d,ppf_out1,N*sizeof(float),cudaMemcpyHostToDevice);
	cudaMemcpy(ppf_out2_d,ppf_out2,N*sizeof(float),cudaMemcpyHostToDevice);

	appliedPolyphasePhysics<<<N,threads>>>(in1_d,prefilter_d,ppf_out1_d); //mabe do a sync after every call?
	appliedPolyphasePhysics<<<N,threads>>>(in2_d,prefilter_d,ppf_out2_d);

	//prepare the fft
	cufftHandle plan;
	cufftComplex *output;
	cudaMalloc((void **) &output, ((N/2)+1)*sizeof(cufftComplex));
	cufftPlan1d(&plan,N, CUFFT_R2C, 1);

	cufftHandle plan2;
	cufftComplex *output2;
	cudaMalloc((void **) &output2, ((N/2)+1)*sizeof(cufftComplex));
	cufftPlan1d(&plan2,N, CUFFT_R2C, 1);

	//do the fft
	cufftExecR2C(plan,(cufftReal *) ppf_out1_d,output);
	cufftExecR2C(plan,(cufftReal *) ppf_out2_d,output2);
	//synchronize
	cudaDeviceSynchronize();

	//prepare cross correlation
	cufftComplex *ccout1;
	cudaMalloc((void **) &ccout1, ((N/2)+1)*sizeof(cufftComplex));
	cufftComplex *ccout2;
	cudaMalloc((void **) &ccout2, ((N/2)+1)*sizeof(cufftComplex));
	//do correlation
	correlate<<<N/2+1,1>>>(output,output2,ccout1);
	correlate<<<N/2+1,1>>>(output2,output,ccout2);
	//copy back to HOST
	cufftComplex *final = (cufftComplex*) malloc((N/2+1)*sizeof(cufftComplex));
	cudaMemcpy(ccout1,final,(N/2+1)*sizeof(cufftComplex),cudaMemcpyDeviceToHost);
	Save_data("output1.csv",final,N);
	cudaMemcpy(ccout2,final,(N/2+1)*sizeof(cufftComplex),cudaMemcpyDeviceToHost);
	//free the data again
	cudaFree(in1_d);	cudaFree(in2_d);
	cudaFree(prefilter_d);	cudaFree(ppf_out1_d);
	cudaFree(output); cudaFree(output2);
	cudaFree(ccout1); cudaFree(ccout2);
	delete[](ppf_out1); delete[](ppf_out2);
	delete[](final);

    return 0;
}

void getdata(vector<vector<float> >& Data, ifstream &myfile, unsigned int axis1, unsigned int axis2) {
    string line;
    int i = 0;
    int j = 0;
	float temp;
    stringstream lineStream;
    Data.resize(axis1,vector<float>(axis2, 0.00));
    while (getline(myfile, line)) {
        lineStream << line;
        string ex2;
        while (getline(lineStream, ex2, ',')) {
            temp = StringToNumber<float>(ex2);
            Data[i][j] = temp;
            j++;
        }
        j = 0;
        i++;
        lineStream.str("");
        lineStream.clear();
    }
}

bool checkaxis2(stringstream &lineStream, unsigned int * axis2) {
    string line;
    vector<string> result;
    string cell;
    while (getline(lineStream, cell, ',')) {
        result.push_back(cell);
    }
    if ((*axis2) != result.size()) {
        return false;
    }
    return true;
}

void checkformat(ifstream &file, unsigned int * axis1, unsigned int * axis2) {
    // first line axis2 should be equal throughout the file.
    // comma separated file.
    vector<string> result;
    string line;
    getline(file, line);
    stringstream lineStream(line);
    string cell;
    while (getline(lineStream, cell, ',')) {
        result.push_back(cell);
    }
    *axis2 = result.size();
    (*axis1)++;
    while (getline(file, line)) {
        stringstream lineStream(line);
        if (checkaxis2(lineStream, axis2)) {
            (*axis1)++;
        } else {
            //not same sizes.
            cout << "Error at line number:" << ((*axis1) + 1) << "\n";
            throw NotSameLengthException();
        }
    }

}

void Read_data(vector<vector<float> >& Data,const string filename) {
    unsigned int axis1 = 0;
    unsigned int axis2 = 0;
    std::ifstream myfile;
    try {
        myfile.open(filename.c_str(), ios::in);
        if (myfile.is_open()) {
            checkformat(myfile, &axis1, &axis2);
            myfile.close();
            myfile.open(filename.c_str(), ios::in);
            getdata(Data, myfile, axis1, axis2);
            myfile.close();
        } else {
            throw FileNotFoundException();
        }
    } catch (exception& e) {
        cout << e.what() << "\nPlease contact the author.";
    }
}

string toString(cufftComplex in){
	return NumberToString<float>(in.x) + string(" ") + NumberToString<float>(in.y) + string("i ");
}

void Save_data(const string filename, cufftComplex *data, unsigned int N){
    std::fstream myfile;
    try {
        myfile.open(filename.c_str(),ios::out);
        if (myfile.is_open()){
            for(unsigned int x = 0; x < N-1; x++){
                myfile << toString(data[x]) + ",";
            }
            myfile << toString(data[N-1]);
            myfile.close();
        }
    } catch (exception& e) {
        cout << e.what() << "\nPlease contact the author.";
    }
}
