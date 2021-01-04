#include "rtweekend.h"

#include "color.h"
#include "hittable_list.h"
#include "moving_sphere.h"
#include "sphere.h"
#include "camera.h"
#include "material.h"
#include "bvh.h"
#include "texture.h"
#include "rtw_stb_image.h"

#include <iostream>
#include "check_cuda.h"
#include <time.h>

__global__ void create_world(hittable** list, hittable_list** world, camera** cam, float aspect_ratio, curandState* local_rand_state, bool BVH, unsigned char *data_cuda, int w1, int h1, unsigned char *data2_cuda, int w2, int h2) {
	if (threadIdx.x == 0 && blockIdx.x == 0) {

		// World
        	//checker_texture* checker = new checker_texture(color(0.0, 0.0, 0.0), color(0.9, 0.9, 0.9));
		image_texture* earth_texture = new image_texture(data_cuda, w1, h1);
		list[0] = new sphere(point3(0, -1000, 0), 1000, new lambertian(earth_texture));

		int i = 1;
		for (int a = -11; a < 11; a++) {
			for (int b = -11; b < 11; b++) {
				float choose_mat = random_float(local_rand_state);
				point3 center(a + 0.9 * random_float(local_rand_state), 0.2, b + 0.9 * random_float(local_rand_state));

				if ((center - point3(4, 0.2, 0)).length() > 0.9) {
					material* sphere_material;

					if (choose_mat < 0.8) {
						// diffuse
						color albedo = color::random(local_rand_state) * color::random(local_rand_state);
						sphere_material = new lambertian(albedo);
						point3 center2 = center + vec3(0, random_float(0,.5,local_rand_state), 0);
						list[i++] = new moving_sphere(center, center2, 0.0, 1.0, 0.2, sphere_material);
					}
					else if (choose_mat < 0.95) {
						// metal
						color albedo = color::random(0.5, 1, local_rand_state);
						float fuzz = random_float(0, 0.5, local_rand_state);
						sphere_material = new metal(albedo, fuzz);
						list[i++] = new sphere(center, 0.2, sphere_material);
					}
					else {
						// glass
						sphere_material = new dielectric(1.5);
						list[i++] = new sphere(center, 0.2, sphere_material);
					}
				}
			}
		}

		material* material1 = new dielectric(1.5);
		list[i++] = new sphere(point3(0, 1, 0), 1.0, material1);

		//material* material2 = new lambertian(color(0.4, 0.2, 0.1));
		image_texture* ball_texture = new image_texture(data2_cuda, w2, h2);
		diffuse_light* difflight = new diffuse_light(ball_texture);
		list[i++] = new sphere(point3(-4, 1, 0), 1.0, difflight);

		material* material3 = new metal(color(0.7, 0.6, 0.5), 0.0);
		list[i++] = new sphere(point3(4, 1, 0), 1.0, material3);

		hittable** temp_ptr = new hittable*;

		if (BVH)
		{
		    *temp_ptr = new bvh_node(new hittable_list(list, i), 0.0f, 1.0f, local_rand_state);
		    *world = new hittable_list(temp_ptr, 1);
		}
		else
		    *world = new hittable_list(list,i);

		// Camera

		point3 lookfrom(0,5,20);
		point3 lookat(0,0,0);
		vec3 vup(0,1,0);
		float dist_to_focus = 20.0;
		float aperture = 0.1;

		*cam = new camera(lookfrom, lookat, vup, 20, aspect_ratio, aperture, dist_to_focus, 0.0, 1.0);
	}
}

__global__ void free_world(hittable** list, hittable_list** world, camera** cam) {
    for(int i=0; i < 22*22+1+3; i++) {
        delete ((sphere *)list[i])->mat_ptr;
        delete list[i];
    }
    delete *world;
    delete *cam;
}

__device__ color ray_color(const ray& r, const color& background, hittable_list** world, int max_depth, curandState *local_rand_state) {
    ray cur_ray = r;
	color cur_attenuation = vec3(1.0f, 1.0f, 1.0f);
    for(int i = 0; i < max_depth; i++) {
        hit_record rec;
        if ((*world)->hit(cur_ray, 0.001f, infinity, rec)) {
			ray scattered;
			color attenuation;
            		color emitted = rec.mat_ptr->emitted(rec.u, rec.v, rec.p);
			if (rec.mat_ptr->scatter(cur_ray, rec, attenuation, scattered, local_rand_state))
			{
				cur_attenuation = emitted + cur_attenuation * attenuation;
				cur_ray = scattered;
			}
			else
				return emitted;
        }
        else
            return background*cur_attenuation;
    }
	return vec3(0.0f, 0.0f, 0.0f); // exceeded recursion
}

__global__ void render(int* fb, int image_width, int image_height, int samples_per_pixel, int max_depth,
						hittable_list** world, camera** cam, curandState* rand_state) {
	int i = threadIdx.x + blockIdx.x * blockDim.x;
	int j = threadIdx.y + blockIdx.y * blockDim.y;
	if ((i >= image_width) || (j >= image_height)) return;
	int pixel_index = j * image_width + i;
    	color background = color(0.3, 0.3, 0.4);

	curandState* local_rand_state = rand_state + pixel_index;
	color pixel_color(0.0f, 0.0f, 0.0f);
	for (int s = 0; s < samples_per_pixel; ++s) {
		float u = float(i + random_float(local_rand_state)) / (image_width - 1);
		float v = float(j + random_float(local_rand_state)) / (image_height - 1);
		ray r = (*cam)->get_ray(u, v, local_rand_state);
		pixel_color += ray_color(r, background, world, max_depth, local_rand_state);
	}
	write_color(fb + pixel_index * 3, pixel_color, samples_per_pixel);
}

unsigned char* load_texture(const char* path, unsigned char *data, int &width, int &height) {
    int components_per_pixel = 3;
    data = stbi_load(path, &width, &height, &components_per_pixel, components_per_pixel);
    if (!data) {
        std::cerr << "ERROR: Could not load texture image file '" << path << "'.\n";
        width = height = 0;
    }
    int size = width*height*components_per_pixel;
    unsigned char *data_cuda;
    checkCudaErrors(cudaMalloc((void **)&data_cuda, size*sizeof(char)));
    checkCudaErrors(cudaMemcpy(data_cuda, data, size*sizeof(char), cudaMemcpyHostToDevice));
    return data_cuda;
}

int main() {

	// Image
    const auto aspect_ratio = 3.0f / 2.0f;
    const int image_width = 1200;
    const int image_height = static_cast<int>(image_width / aspect_ratio);
    const int samples_per_pixel = 500;
    const int max_depth = 50;
    const bool BVH = false;

    int thread_width = 24;
    int thread_height = 16;
    cudaSetDevice(1);
    curandState *d_rand_state_world;
    checkCudaErrors(cudaMalloc((void **)&d_rand_state_world, 1*sizeof(curandState)));

    // we need that 2nd random state to be initialized for the world creation
    random_init<<<1,1>>>(1, 1, d_rand_state_world);
    checkCudaErrors(cudaGetLastError());
    checkCudaErrors(cudaDeviceSynchronize());

    //load texture from picture
    const char* filename = "th1.jpg";
    const char* filename2 = "th3.jpg";
    int w1, h1, w2, h2;
    unsigned char *data = 0, *data2 = 0;
    unsigned char *data_cuda = load_texture(filename, data, w1, h1);
    unsigned char *data2_cuda = load_texture(filename2, data2, w2, h2);
    
    // make our world of hitables & the camera
    hittable **d_list;
    int num_hitables = 22*22+1+3;
    checkCudaErrors(cudaMalloc((void **)&d_list, num_hitables*sizeof(hittable *)));
    hittable_list **d_world;
    checkCudaErrors(cudaMalloc((void **)&d_world, sizeof(hittable_list *)));
    camera **d_camera;
    checkCudaErrors(cudaMalloc((void **)&d_camera, sizeof(camera *)));
    create_world<<<1,1>>>(d_list, d_world, d_camera, aspect_ratio, d_rand_state_world, BVH, data_cuda, w1, h1, data2_cuda, w2, h2);
    checkCudaErrors(cudaGetLastError());
    checkCudaErrors(cudaDeviceSynchronize());

    std::cerr << "Rendering a " << image_width << "x" << image_height << " image with " << samples_per_pixel << " samples per pixel ";
    if (BVH)
        std::cerr << "with ";
    else
        std::cerr << "without ";
    std::cerr << "BVH ";
    std::cerr << "in " << thread_width << "x" << thread_height << " blocks.\n";

	int num_pixels = image_width * image_height;
	size_t fb_size = 3 * num_pixels * sizeof(int);

	// allocate FB
	int* fb;
	checkCudaErrors(cudaMallocManaged((void**)&fb, fb_size));

	dim3 blocks(image_width / thread_width + 1, image_height / thread_height + 1);
	dim3 threads(thread_width, thread_height);

        // allocate random state
        curandState *d_rand_state;
	checkCudaErrors(cudaMalloc((void**)&d_rand_state, num_pixels * sizeof(curandState)));
        random_init<<<blocks, threads>>>(image_width, image_height, d_rand_state);
        checkCudaErrors(cudaGetLastError());
	checkCudaErrors(cudaDeviceSynchronize());

	clock_t start, stop;
	start = clock();
	// Render our buffer
	render <<<blocks, threads>>> (fb, image_width, image_height, samples_per_pixel, max_depth, d_world, d_camera, d_rand_state);
	checkCudaErrors(cudaGetLastError());
	checkCudaErrors(cudaDeviceSynchronize());
	stop = clock();
	double timer_seconds = ((double)(stop - start)) / CLOCKS_PER_SEC;
	std::cerr << "took " << timer_seconds << " seconds.\n";

	// Output FB as Image
	std::cout << "P3\n" << image_width << ' ' << image_height << "\n255\n";
	for (int j = image_height - 1; j >= 0; j--) {
		for (int i = 0; i < image_width; i++) {
			size_t pixel_index = j * 3 * image_width + i * 3;
			std::cout << fb[pixel_index + 0] << ' ' << fb[pixel_index + 1] << ' ' << fb[pixel_index + 2] << '\n';
		}
	}

    // clean up
    checkCudaErrors(cudaDeviceSynchronize());
    //free_world<<<1,1>>>(d_list,d_world,d_camera);
    checkCudaErrors(cudaGetLastError());
    checkCudaErrors(cudaFree(data_cuda));
    STBI_FREE(data);
    checkCudaErrors(cudaFree(data2_cuda));
    STBI_FREE(data2);
    checkCudaErrors(cudaFree(d_camera));
    checkCudaErrors(cudaFree(d_world));
    checkCudaErrors(cudaFree(d_list));
    checkCudaErrors(cudaFree(d_rand_state));
    checkCudaErrors(cudaFree(fb));

    // useful for cuda-memcheck --leak-check full
    cudaDeviceReset();
}
